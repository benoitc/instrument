%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc OpenTelemetry-compatible Tracer API.
%%
%% This module provides a native span implementation with W3C TraceContext
%% format support. Spans are stored in the process dictionary via the
%% context system.
%%
%% == Example Usage ==
%% ```
%% instrument_tracer:with_span(<<"process_request">>, fun() ->
%%   instrument_tracer:set_attributes(#{<<"user.id">> => UserId}),
%%   Result = process(),
%%   instrument_tracer:set_status(ok),
%%   Result
%% end).
%% '''
-module(instrument_tracer).
-author("benoitc").

%% TracerProvider API
-export([
  get_tracer/1,
  get_tracer/2
]).

%% Span lifecycle
-export([
  start_span/1,
  start_span/2,
  with_span/2,
  with_span/3,
  end_span/0,
  end_span/1,
  current_span/0
]).

%% Span modification
-export([
  set_attributes/1,
  set_attribute/2,
  add_event/1,
  add_event/2,
  set_status/1,
  set_status/2,
  record_exception/1,
  record_exception/2,
  add_link/1,
  update_name/1
]).

%% SpanContext
-export([
  span_ctx/0,
  span_ctx/1,
  trace_id/0,
  trace_id/1,
  span_id/0,
  span_id/1,
  is_recording/0,
  is_sampled/0
]).

%% Span export hooks (for custom exporters)
-export([
  register_exporter/1,
  unregister_exporter/1
]).

-include("instrument_otel.hrl").

-define(SPAN_KEY, '$instrument_span').
-define(SPAN_STACK_KEY, '$instrument_span_stack').
-define(TRACER_KEY, '$instrument_tracer').
-define(EXPORTERS_CACHE_KEY, '$instrument_exporters').

-type span_opts() :: #{
  kind => client | server | producer | consumer | internal,
  attributes => map(),
  links => [#span_link{}],
  start_time => integer(),
  parent => #span_ctx{} | undefined,
  span_id => binary(),    %% Custom 8-byte span ID or 16-char hex string
  tracer => #tracer{} | undefined  %% Tracer that created this span (for scope info)
}.

-type tracer() :: #tracer{}.
-type span() :: #span{}.

-export_type([tracer/0, span/0, span_opts/0]).

%% ============================================================================
%% TracerProvider API
%% ============================================================================

%% @doc Gets or creates a Tracer with the given name.
-spec get_tracer(binary() | atom()) -> tracer().
get_tracer(Name) ->
  get_tracer(Name, #{}).

%% @doc Gets or creates a Tracer with the given name and options.
-spec get_tracer(binary() | atom(), map()) -> tracer().
get_tracer(Name, Opts) when is_atom(Name) ->
  get_tracer(atom_to_binary(Name, utf8), Opts);
get_tracer(Name, Opts) when is_binary(Name), is_map(Opts) ->
  Version = maps:get(version, Opts, undefined),
  SchemaUrl = maps:get(schema_url, Opts, undefined),
  Resource = maps:get(resource, Opts, undefined),
  #tracer{
    name = Name,
    version = Version,
    schema_url = SchemaUrl,
    resource = Resource
  }.

%% ============================================================================
%% Span Lifecycle
%% ============================================================================

%% @doc Starts a new span with the given name.
-spec start_span(binary() | atom()) -> span().
start_span(Name) ->
  start_span(Name, #{}).

%% @doc Starts a new span with the given name and options.
-spec start_span(binary() | atom(), span_opts()) -> span().
start_span(Name, Opts) when is_atom(Name) ->
  start_span(atom_to_binary(Name, utf8), Opts);
start_span(Name, Opts) when is_binary(Name), is_map(Opts) ->
  %% Early exit when tracing is globally disabled
  case instrument_config:is_tracing_enabled() of
    false ->
      Span = noop_span(Name),
      attach_span(Span),
      Span;
    true ->
      start_span_impl(Name, Opts)
  end.

%% @private
start_span_impl(Name, Opts) ->
  Kind = maps:get(kind, Opts, internal),
  Attributes = maps:get(attributes, Opts, #{}),
  Links = maps:get(links, Opts, []),
  StartTime = maps:get(start_time, Opts, erlang:system_time(nanosecond)),
  Tracer = maps:get(tracer, Opts, undefined),

  %% Get parent context
  ParentCtx = case maps:get(parent, Opts, undefined) of
    undefined -> current_span_ctx();
    P -> P
  end,

  %% Generate IDs
  {TraceId, ParentSpanCtx} = case ParentCtx of
    undefined ->
      %% New trace
      {instrument_id:generate_trace_id(), undefined};
    #span_ctx{trace_id = TId} ->
      %% Continue existing trace
      {TId, ParentCtx}
  end,
  SpanId = case maps:get(span_id, Opts, undefined) of
    undefined -> instrument_id:generate_span_id();
    CustomSpanId when is_binary(CustomSpanId), byte_size(CustomSpanId) =:= 8 ->
      CustomSpanId;
    CustomSpanIdHex when is_binary(CustomSpanIdHex), byte_size(CustomSpanIdHex) =:= 16 ->
      instrument_id:hex_to_span_id(CustomSpanIdHex)
  end,

  %% Make sampling decision
  #sampling_result{
    decision = Decision,
    attributes = SamplerAttrs,
    trace_state = SamplerTraceState
  } = instrument_sampler:should_sample(TraceId, Name, Kind, Attributes, Links, ParentSpanCtx),

  %% Determine trace flags and recording state from sampling decision
  {TraceFlags, IsRecording} = case Decision of
    record_and_sample -> {1, true};
    record_only -> {0, true};
    drop -> {0, false}
  end,

  %% Create span context
  SpanCtx = #span_ctx{
    trace_id = TraceId,
    span_id = SpanId,
    trace_flags = TraceFlags,
    trace_state = SamplerTraceState,
    is_remote = false
  },

  %% Merge sampler attributes with provided attributes
  MergedAttributes = maps:merge(SamplerAttrs, Attributes),

  %% Apply limits to initial attributes and links
  AttrLimit = instrument_config:get_span_attribute_count_limit(),
  LinkLimit = instrument_config:get_span_link_count_limit(),

  {LimitedAttrs, DroppedAttrsCount} = apply_attribute_limit(MergedAttributes, AttrLimit),
  {LimitedLinks, DroppedLinksCount} = apply_link_limit(Links, LinkLimit),

  %% Create span
  Span = #span{
    name = Name,
    ctx = SpanCtx,
    parent_ctx = ParentSpanCtx,
    tracer = Tracer,
    kind = Kind,
    start_time = StartTime,
    attributes = LimitedAttrs,
    links = LimitedLinks,
    status = unset,
    is_recording = IsRecording,
    dropped_attributes_count = DroppedAttrsCount,
    dropped_links_count = DroppedLinksCount
  },

  %% Notify span processors of span start (skip for non-recording spans)
  %% Uses inline version to avoid gen_server hop
  FinalSpan = case IsRecording of
    true ->
      try
        instrument_span_processor:on_start_inline(Span, ParentSpanCtx)
      catch
        _:_ -> Span
      end;
    false ->
      Span
  end,

  %% Attach to context
  attach_span(FinalSpan),

  %% Enable tracing if flight recorder is active
  %% We need to trace if:
  %% 1. This is a root span (no parent), OR
  %% 2. This process doesn't already have tracing enabled (async parent case)
  case instrument_flight_recorder:is_enabled() of
    true ->
      %% Check if this process already has tracing enabled
      AlreadyTraced = get('$instrument_flight_label') =/= undefined,
      case {ParentSpanCtx, AlreadyTraced} of
        {_, true} ->
          %% Already traced (either root or spawned child), just update label if needed
          ok;
        {undefined, false} ->
          %% New root span - enable tracing
          enable_flight_tracing(TraceId);
        {#span_ctx{}, false} ->
          %% Async parent case: pre-existing process starting span with remote parent
          %% Enable tracing for this process too
          enable_flight_tracing(TraceId)
      end;
    false ->
      ok
  end,

  FinalSpan.

%% @private Enable flight recorder tracing for this process.
enable_flight_tracing(TraceId) ->
  Label = binary:decode_unsigned(TraceId),
  %% Create a session resource - children will inherit this via set_on_spawn
  %% and will be able to detect when the session becomes inactive
  SessionRef = instrument_tracer_nif:create_session_resource(),
  %% Store label and session in process dictionary
  put('$instrument_flight_label', Label),
  put('$instrument_flight_session_ref', SessionRef),
  %% Mark that THIS process enabled tracing (for cleanup in end_span)
  put('$instrument_flight_owner', true),
  %% Get tracer state with worker pool info and add session_ref
  TracerState = instrument_flight_recorder:tracer_state(TraceId),
  TracerStateWithSession = TracerState#{session_ref => SessionRef},
  %% Enable tracing with NIF-based tracer
  %% Catch errors if process is already being traced
  try
    erlang:trace(self(), true, [
      send, 'receive', set_on_spawn,
      {tracer, instrument_tracer_nif, TracerStateWithSession}
    ])
  catch
    error:badarg -> ok
  end.

%% @private Creates a minimal no-op span when tracing is disabled.
noop_span(Name) ->
  #span{
    name = Name,
    ctx = #span_ctx{
      trace_id = <<0:128>>,
      span_id = <<0:64>>,
      trace_flags = 0,
      trace_state = [],
      is_remote = false
    },
    parent_ctx = undefined,
    tracer = undefined,
    kind = internal,
    start_time = 0,
    end_time = undefined,
    attributes = #{},
    events = [],
    links = [],
    status = unset,
    is_recording = false
  }.

%% @doc Executes a function within a span.
-spec with_span(binary() | atom(), fun(() -> Result)) -> Result when Result :: term().
with_span(Name, Fun) ->
  with_span(Name, #{}, Fun).

%% @doc Executes a function within a span with options.
-spec with_span(binary() | atom(), span_opts(), fun(() -> Result)) -> Result when Result :: term().
with_span(Name, Opts, Fun) when is_function(Fun, 0) ->
  Span = start_span(Name, Opts),
  try
    Fun()
  catch
    Class:Reason:Stacktrace ->
      record_exception(Reason, #{stacktrace => Stacktrace}),
      set_status(error, format_error(Class, Reason)),
      erlang:raise(Class, Reason, Stacktrace)
  after
    end_span(Span)
  end.

%% @doc Ends the current span.
-spec end_span() -> ok.
end_span() ->
  case current_span() of
    undefined -> ok;
    Span -> end_span(Span)
  end.

%% @doc Ends a specific span.
%% The span parameter is used to identify which span to end via its span_id.
%% The actual span data is retrieved from context to capture any modifications.
-spec end_span(span()) -> ok.
end_span(#span{is_recording = false} = Span) ->
  %% Non-recording spans still need to be detached from context
  detach_span(Span),
  ok;
end_span(#span{ctx = #span_ctx{span_id = SpanId}} = OriginalSpan) ->
  %% Get the current span from context (may have been modified)
  %% Use the span_id to verify we're ending the right span
  SpanToEnd = case current_span() of
    #span{ctx = #span_ctx{span_id = SpanId}} = CurrentSpan ->
      %% Current span matches, use it (has modifications)
      CurrentSpan;
    _ ->
      %% Fallback to original span if context doesn't match
      OriginalSpan
  end,
  EndTime = erlang:system_time(nanosecond),
  %% Call on_end while span still shows is_recording = true
  %% Reverse events and links (were prepended for O(1) add, now restore order)
  SpanWithEndTime = SpanToEnd#span{
    end_time = EndTime,
    events = lists:reverse(SpanToEnd#span.events),
    links = lists:reverse(SpanToEnd#span.links)
  },
  %% Uses inline version to avoid gen_server hop
  try
    instrument_span_processor:on_end_inline(SpanWithEndTime)
  catch
    _:_ -> ok
  end,
  %% Now mark as not recording for final state
  FinalSpan = SpanWithEndTime#span{is_recording = false},
  %% Export only if sampled (trace_flags=1), not for record_only spans
  case SpanWithEndTime#span.ctx of
    #span_ctx{trace_flags = 1} -> export_span(FinalSpan);
    _ -> ok
  end,
  %% Disable tracing if this process owns the trace (enabled it)
  %% This handles both root spans and async parent spans
  case erase('$instrument_flight_owner') of
    true ->
      %% Clear label from process dictionary
      erase('$instrument_flight_label'),
      %% Deactivate session resource - children will see this on their next
      %% trace event and return 'remove' to stop being traced
      case erase('$instrument_flight_session_ref') of
        undefined -> ok;
        SessionRef -> instrument_tracer_nif:deactivate_session_resource(SessionRef)
      end,
      %% Fully disable tracing for this process (all flags + tracer)
      catch erlang:trace(self(), false, [send, 'receive', set_on_spawn, set_on_link]);
    _ ->
      ok
  end,
  %% Detach from context using the span we're ending
  detach_span(SpanToEnd),
  ok.

%% @doc Gets the current span.
-spec current_span() -> span() | undefined.
current_span() ->
  Ctx = instrument_context:current(),
  instrument_context:get_value(Ctx, ?SPAN_KEY).

%% ============================================================================
%% Span Modification
%% ============================================================================

%% @doc Sets multiple attributes on the current span.
%% Enforces span attribute count limit per OTel spec.
-spec set_attributes(map()) -> ok.
set_attributes(Attrs) when is_map(Attrs) ->
  update_current_span(fun(Span) ->
    Limit = instrument_config:get_span_attribute_count_limit(),
    CurrentAttrs = Span#span.attributes,
    CurrentCount = maps:size(CurrentAttrs),
    MergedAttrs = maps:merge(CurrentAttrs, Attrs),
    MergedCount = maps:size(MergedAttrs),
    %% Only count newly added attributes (not updates to existing keys)
    NewKeys = maps:size(Attrs) - maps:size(maps:with(maps:keys(Attrs), CurrentAttrs)),
    case CurrentCount + NewKeys > Limit of
      true ->
        %% At or over limit - only allow updates to existing keys
        AllowedAttrs = maps:with(maps:keys(CurrentAttrs), Attrs),
        DroppedCount = NewKeys,
        Span#span{
          attributes = maps:merge(CurrentAttrs, AllowedAttrs),
          dropped_attributes_count = Span#span.dropped_attributes_count + DroppedCount
        };
      false when MergedCount > Limit ->
        %% Would exceed limit - take what we can
        CanAdd = Limit - CurrentCount,
        NewKeysToAdd = lists:sublist(
          [K || K <- maps:keys(Attrs), not maps:is_key(K, CurrentAttrs)],
          CanAdd
        ),
        AllowedNewAttrs = maps:with(NewKeysToAdd, Attrs),
        UpdatedExisting = maps:with(maps:keys(CurrentAttrs), Attrs),
        DroppedCount = NewKeys - length(NewKeysToAdd),
        Span#span{
          attributes = maps:merge(maps:merge(CurrentAttrs, AllowedNewAttrs), UpdatedExisting),
          dropped_attributes_count = Span#span.dropped_attributes_count + DroppedCount
        };
      false ->
        Span#span{attributes = MergedAttrs}
    end
  end).

%% @doc Sets a single attribute on the current span.
-spec set_attribute(term(), term()) -> ok.
set_attribute(Key, Value) ->
  set_attributes(#{Key => Value}).

%% @doc Adds an event to the current span.
-spec add_event(binary()) -> ok.
add_event(Name) ->
  add_event(Name, #{}).

%% @doc Adds an event with attributes to the current span.
%% Enforces span event count limit per OTel spec.
-spec add_event(binary(), map()) -> ok.
add_event(Name, Attrs) when is_binary(Name), is_map(Attrs) ->
  Event = #span_event{
    name = Name,
    %% Use system_time (Unix epoch) not monotonic_time for OTLP compatibility
    timestamp = erlang:system_time(nanosecond),
    attributes = Attrs
  },
  update_current_span(fun(Span) ->
    Limit = instrument_config:get_span_event_count_limit(),
    CurrentCount = length(Span#span.events),
    case CurrentCount >= Limit of
      true ->
        %% At limit - drop the event
        Span#span{dropped_events_count = Span#span.dropped_events_count + 1};
      false ->
        Span#span{events = [Event | Span#span.events]}
    end
  end).

%% @doc Sets the status of the current span to ok.
-spec set_status(ok | error) -> ok.
set_status(ok) ->
  update_current_span(fun(Span) ->
    Span#span{status = ok}
  end);
set_status(error) ->
  set_status(error, <<>>).

%% @doc Sets the status of the current span with description.
-spec set_status(ok | error, binary()) -> ok.
set_status(ok, _Description) ->
  set_status(ok);
set_status(error, Description) when is_binary(Description) ->
  update_current_span(fun(Span) ->
    Span#span{status = {error, Description}}
  end);
set_status(error, Description) when is_list(Description) ->
  set_status(error, list_to_binary(Description)).

%% @doc Records an exception on the current span.
-spec record_exception(term()) -> ok.
record_exception(Exception) ->
  record_exception(Exception, #{}).

%% @doc Records an exception with attributes on the current span.
-spec record_exception(term(), map()) -> ok.
record_exception(Exception, Attrs) when is_map(Attrs) ->
  ExceptionType = get_exception_type(Exception),
  ExceptionMsg = format_exception(Exception),
  Stacktrace = maps:get(stacktrace, Attrs, []),
  EventAttrs = maps:merge(#{
    <<"exception.type">> => ExceptionType,
    <<"exception.message">> => ExceptionMsg,
    <<"exception.stacktrace">> => format_stacktrace(Stacktrace)
  }, maps:remove(stacktrace, Attrs)),
  add_event(<<"exception">>, EventAttrs).

%% @doc Adds a link to the current span.
-spec add_link(#span_ctx{} | #{}) -> ok.
add_link(#span_ctx{} = SpanCtx) ->
  add_link(SpanCtx, #{});
add_link(#{span_ctx := SpanCtx} = Opts) ->
  Attrs = maps:get(attributes, Opts, #{}),
  add_link(SpanCtx, Attrs).

add_link(#span_ctx{} = SpanCtx, Attrs) ->
  Link = #span_link{
    ctx = SpanCtx,
    attributes = Attrs
  },
  update_current_span(fun(Span) ->
    Limit = instrument_config:get_span_link_count_limit(),
    CurrentCount = length(Span#span.links),
    case CurrentCount >= Limit of
      true ->
        %% At limit - drop the link
        Span#span{dropped_links_count = Span#span.dropped_links_count + 1};
      false ->
        Span#span{links = [Link | Span#span.links]}
    end
  end).

%% @doc Updates the name of the current span.
-spec update_name(binary()) -> ok.
update_name(Name) when is_binary(Name) ->
  update_current_span(fun(Span) ->
    Span#span{name = Name}
  end).

%% ============================================================================
%% SpanContext
%% ============================================================================

%% @doc Gets the span context of the current span.
-spec span_ctx() -> #span_ctx{} | undefined.
span_ctx() ->
  case current_span() of
    undefined -> current_span_ctx();
    #span{ctx = Ctx} -> Ctx
  end.

%% @doc Gets the span context of a specific span.
-spec span_ctx(span()) -> #span_ctx{}.
span_ctx(#span{ctx = Ctx}) ->
  Ctx.

%% @doc Gets the trace ID of the current span.
-spec trace_id() -> binary() | undefined.
trace_id() ->
  case span_ctx() of
    undefined -> undefined;
    #span_ctx{trace_id = TraceId} -> instrument_id:trace_id_to_hex(TraceId)
  end.

%% @doc Gets the trace ID of a specific span.
-spec trace_id(span()) -> binary().
trace_id(#span{ctx = #span_ctx{trace_id = TraceId}}) ->
  instrument_id:trace_id_to_hex(TraceId).

%% @doc Gets the span ID of the current span.
-spec span_id() -> binary() | undefined.
span_id() ->
  case span_ctx() of
    undefined -> undefined;
    #span_ctx{span_id = SpanId} -> instrument_id:span_id_to_hex(SpanId)
  end.

%% @doc Gets the span ID of a specific span.
-spec span_id(span()) -> binary().
span_id(#span{ctx = #span_ctx{span_id = SpanId}}) ->
  instrument_id:span_id_to_hex(SpanId).

%% @doc Checks if the current span is recording.
-spec is_recording() -> boolean().
is_recording() ->
  case current_span() of
    undefined -> false;
    #span{is_recording = Recording} -> Recording
  end.

%% @doc Checks if the current span is sampled.
-spec is_sampled() -> boolean().
is_sampled() ->
  case span_ctx() of
    undefined -> false;
    #span_ctx{trace_flags = Flags} -> (Flags band 1) =:= 1
  end.

%% ============================================================================
%% Span Export Hooks
%% ============================================================================

%% @doc Registers a span exporter.
%% The exporter must be a function that takes a span record.
%% Thread-safe: uses ETS for atomic operations.
-spec register_exporter(fun((span()) -> ok)) -> ok.
register_exporter(Exporter) when is_function(Exporter, 1) ->
  ets:insert(instrument_span_exporters, {exporter, Exporter}),
  refresh_exporter_cache(),
  ok.

%% @doc Unregisters a span exporter.
%% Thread-safe: uses ETS for atomic operations.
-spec unregister_exporter(fun((span()) -> ok)) -> ok.
unregister_exporter(Exporter) ->
  ets:delete_object(instrument_span_exporters, {exporter, Exporter}),
  refresh_exporter_cache(),
  ok.

%% ============================================================================
%% Internal Functions
%% ============================================================================

current_span_ctx() ->
  Ctx = instrument_context:current(),
  instrument_context:get_value(Ctx, span_ctx).

attach_span(Span) ->
  Ctx = instrument_context:current(),
  %% Push current span onto stack before attaching the new one
  CurrentSpan = instrument_context:get_value(Ctx, ?SPAN_KEY),
  Stack = instrument_context:get_value(Ctx, ?SPAN_STACK_KEY, []),
  NewStack = case CurrentSpan of
    undefined -> Stack;
    _ -> [CurrentSpan | Stack]
  end,
  NewCtx = instrument_context:set_value(Ctx, ?SPAN_KEY, Span),
  NewCtx2 = instrument_context:set_value(NewCtx, span_ctx, Span#span.ctx),
  NewCtx3 = instrument_context:set_value(NewCtx2, ?SPAN_STACK_KEY, NewStack),
  %% Use set_current to avoid leaking process dictionary entries.
  instrument_context:set_current(NewCtx3).

detach_span(#span{parent_ctx = undefined}) ->
  Ctx = instrument_context:current(),
  NewCtx = instrument_context:remove_value(Ctx, ?SPAN_KEY),
  NewCtx2 = instrument_context:remove_value(NewCtx, span_ctx),
  NewCtx3 = instrument_context:remove_value(NewCtx2, ?SPAN_STACK_KEY),
  instrument_context:set_current(NewCtx3);
detach_span(#span{parent_ctx = ParentCtx}) ->
  Ctx = instrument_context:current(),
  %% Pop the parent span from stack and restore it
  Stack = instrument_context:get_value(Ctx, ?SPAN_STACK_KEY, []),
  {NewCtx, NewStack} = case Stack of
    [] ->
      %% No parent span on stack, just remove current
      Ctx1 = instrument_context:remove_value(Ctx, ?SPAN_KEY),
      {Ctx1, []};
    [ParentSpan | Rest] ->
      %% Restore parent span
      Ctx1 = instrument_context:set_value(Ctx, ?SPAN_KEY, ParentSpan),
      {Ctx1, Rest}
  end,
  NewCtx2 = instrument_context:set_value(NewCtx, span_ctx, ParentCtx),
  NewCtx3 = case NewStack of
    [] -> instrument_context:remove_value(NewCtx2, ?SPAN_STACK_KEY);
    _ -> instrument_context:set_value(NewCtx2, ?SPAN_STACK_KEY, NewStack)
  end,
  instrument_context:set_current(NewCtx3).

update_current_span(UpdateFun) ->
  case current_span() of
    undefined -> ok;
    #span{is_recording = false} -> ok;
    Span ->
      NewSpan = UpdateFun(Span),
      Ctx = instrument_context:current(),
      NewCtx = instrument_context:set_value(Ctx, ?SPAN_KEY, NewSpan),
      instrument_context:set_current(NewCtx),
      ok
  end.

export_span(Span) ->
  %% Get exporters from cache (O(1) persistent_term read)
  Exporters = persistent_term:get(?EXPORTERS_CACHE_KEY, []),
  lists:foreach(fun(Exporter) ->
    try
      Exporter(Span)
    catch
      Class:Reason:Stacktrace ->
        logger:warning("Span exporter failed: ~p:~p",
                      [Class, Reason],
                      #{error_logger => #{tag => warning_msg},
                        stacktrace => Stacktrace})
    end
  end, Exporters).

%% @private Refresh the exporter cache in persistent_term.
refresh_exporter_cache() ->
  Exporters = try
    [E || {exporter, E} <- ets:tab2list(instrument_span_exporters)]
  catch
    error:badarg -> []  %% Table doesn't exist yet
  end,
  persistent_term:put(?EXPORTERS_CACHE_KEY, Exporters).

get_exception_type(Exception) when is_atom(Exception) ->
  atom_to_binary(Exception, utf8);
get_exception_type({Exception, _}) when is_atom(Exception) ->
  atom_to_binary(Exception, utf8);
get_exception_type(_) ->
  <<"unknown">>.

format_exception(Exception) ->
  iolist_to_binary(io_lib:format("~p", [Exception])).

format_error(Class, Reason) ->
  iolist_to_binary(io_lib:format("~p:~p", [Class, Reason])).

format_stacktrace([]) ->
  <<>>;
format_stacktrace(Stacktrace) when is_list(Stacktrace) ->
  Lines = [format_stack_entry(Entry) || Entry <- Stacktrace],
  iolist_to_binary(lists:join(<<"\n">>, Lines));
format_stacktrace(_) ->
  <<>>.

format_stack_entry({M, F, A, Loc}) when is_integer(A) ->
  File = proplists:get_value(file, Loc, "unknown"),
  Line = proplists:get_value(line, Loc, 0),
  iolist_to_binary(io_lib:format("~s:~B in ~s:~s/~B", [File, Line, M, F, A]));
format_stack_entry({M, F, A, Loc}) when is_list(A) ->
  format_stack_entry({M, F, length(A), Loc});
format_stack_entry(Entry) ->
  iolist_to_binary(io_lib:format("~p", [Entry])).

%% @private Apply attribute count limit to initial attributes.
apply_attribute_limit(Attrs, Limit) ->
  Count = maps:size(Attrs),
  case Count > Limit of
    true ->
      %% Take first Limit keys (arbitrary but deterministic order)
      Keys = lists:sublist(maps:keys(Attrs), Limit),
      {maps:with(Keys, Attrs), Count - Limit};
    false ->
      {Attrs, 0}
  end.

%% @private Apply link count limit to initial links.
apply_link_limit(Links, Limit) ->
  Count = length(Links),
  case Count > Limit of
    true ->
      {lists:sublist(Links, Limit), Count - Limit};
    false ->
      {Links, 0}
  end.
