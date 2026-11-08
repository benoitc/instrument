%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Flight recorder for low-overhead message tracing.
%%
%% This module captures message passing events at VM level with minimal overhead,
%% correlating them with OpenTelemetry spans via trace_id labels.
%%
%% Uses erlang:trace with a custom erl_tracer NIF that distributes events
%% across a pool of workers, avoiding the single-process bottleneck of seq_trace.
%%
%% Memory is bounded: each worker queues at most `flight_recorder_max_queue'
%% events (extra events are dropped and counted in stats/0), message payloads
%% larger than `flight_recorder_max_payload_bytes' are stored as
%% `{truncated, Size}', and the buffer is trimmed to
%% `flight_recorder_buffer_size' events as soon as a worker sees it over.
%%
%% == Example Usage ==
%% ```
%% %% Disabled by default: enable it, or set flight_recorder_auto_enable
%% ok = instrument_flight_recorder:enable(),
%% instrument_tracer:with_span(<<"request">>, fun() ->
%%   %% All message passing captured with trace_id label
%%   gen_server:call(some_server, request),
%%   another_process ! message
%% end),
%%
%% %% On error or slow request, dump the trace
%% TraceId = instrument_tracer:trace_id(),
%% Events = instrument_flight_recorder:get_trace(TraceId).
%% '''
-module(instrument_flight_recorder).
-author("benoitc").

-behaviour(gen_server).

%% API
-export([
  start_link/0,
  start_link/1,
  enable/0,
  disable/0,
  is_enabled/0,
  tracer_state/1,
  get_trace/1,
  dump_trace/1,
  dump_all/0,
  clear/0,
  mark/1,
  mark/2,
  stats/0,
  set_buffer_size/1,
  maybe_evict/0
]).

%% gen_server callbacks
-export([
  init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3
]).

-define(SERVER, ?MODULE).
-define(BUFFER_TABLE, instrument_flight_buffer).
-define(DEFAULT_BUFFER_SIZE, 65536).  %% 64K events
-define(ENABLED_KEY, '$instrument_flight_recorder_enabled').
-define(LABEL_KEY, '$instrument_flight_label').
-define(BUFFER_LIMIT_KEY, '$instrument_flight_buffer_limit').
-define(EVICT_PENDING_KEY, '$instrument_flight_evict_pending').

-record(state, {
  buffer_size :: pos_integer()
}).

%% ============================================================================
%% API
%% ============================================================================

%% @doc Starts the flight recorder with default options.
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
  start_link([]).

%% @doc Starts the flight recorder with options.
-spec start_link(list()) -> {ok, pid()} | ignore | {error, term()}.
start_link(Args) ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, Args, []).

%% @doc Enables the flight recorder.
%% Starts the worker pool and enables tracing.
-spec enable() -> ok.
enable() ->
  gen_server:call(?SERVER, enable).

%% @doc Disables the flight recorder.
%% Stops the worker pool. Buffer is retained.
-spec disable() -> ok.
disable() ->
  gen_server:call(?SERVER, disable).

%% @doc Checks if the flight recorder is enabled.
-spec is_enabled() -> boolean().
is_enabled() ->
  persistent_term:get(?ENABLED_KEY, false).

%% @doc Gets the tracer state for use with erlang:trace.
-spec tracer_state(binary()) -> map().
tracer_state(TraceId) when is_binary(TraceId) ->
  Label = binary:decode_unsigned(TraceId),
  instrument_tracer_pool:get_tracer_state(Label).

%% @doc Gets all events for a trace ID.
%% Returns events as a list of {Timestamp, Event} tuples.
-spec get_trace(binary() | integer()) -> [{integer(), term()}].
get_trace(TraceId) when is_binary(TraceId) ->
  %% Convert binary trace_id to integer label
  Label = binary:decode_unsigned(TraceId),
  get_trace(Label);
get_trace(Label) when is_integer(Label) ->
  try
    ets:select(?BUFFER_TABLE, [
      {{'$1', Label, '$2'}, [], [{{'$1', '$2'}}]}
    ])
  catch
    error:badarg -> []
  end.

%% @doc Gets and clears all events for a trace ID.
-spec dump_trace(binary() | integer()) -> [{integer(), term()}].
dump_trace(TraceId) when is_binary(TraceId) ->
  Label = binary:decode_unsigned(TraceId),
  dump_trace(Label);
dump_trace(Label) when is_integer(Label) ->
  Events = get_trace(Label),
  %% Delete matching events
  try
    ets:select_delete(?BUFFER_TABLE, [
      {{'_', Label, '_'}, [], [true]}
    ])
  catch
    error:badarg -> ok
  end,
  Events.

%% @doc Gets all events in the buffer.
-spec dump_all() -> [{integer(), integer(), term()}].
dump_all() ->
  try
    ets:select(?BUFFER_TABLE, [
      {{'$1', '$2', '$3'}, [], [{{'$1', '$2', '$3'}}]}
    ])
  catch
    error:badarg -> []
  end.

%% @doc Clears all events from the buffer.
-spec clear() -> ok.
clear() ->
  gen_server:call(?SERVER, clear).

%% @doc Adds a custom marker event with current trace context.
-spec mark(binary()) -> ok.
mark(Name) ->
  mark(Name, #{}).

%% @doc Adds a custom marker event with metadata.
-spec mark(binary(), map()) -> ok.
mark(Name, Meta) when is_binary(Name), is_map(Meta) ->
  case is_enabled() of
    false -> ok;
    true ->
      %% Get current trace label - check process dict first, then tracer state
      %% (for spawned children that inherit tracing via set_on_spawn)
      Label = get_current_label(),
      case Label of
        undefined -> ok;
        _ ->
          Timestamp = erlang:monotonic_time(),
          Key = {Timestamp, erlang:unique_integer([monotonic])},
          Event = {marker, Name,
                   instrument_flight_tracer:truncate(Meta, instrument_flight_tracer:max_payload())},
          try
            ets:insert(?BUFFER_TABLE, {Key, Label, Event})
          catch
            error:badarg -> ok
          end,
          ok
      end
  end.

%% @doc Returns statistics about the flight recorder.
-spec stats() -> map().
stats() ->
  gen_server:call(?SERVER, stats).

%% @doc Called by tracer workers after inserting events: asks the recorder to
%% evict when the buffer is over its limit. Concurrent requests coalesce into
%% one eviction.
-spec maybe_evict() -> ok.
maybe_evict() ->
  Limit = persistent_term:get(?BUFFER_LIMIT_KEY, ?DEFAULT_BUFFER_SIZE),
  case instrument_lib:safe_apply(ets, info, [?BUFFER_TABLE, size], 0) of
    Size when is_integer(Size), Size > Limit ->
      case persistent_term:get(?EVICT_PENDING_KEY, undefined) of
        undefined -> ok;
        Pending ->
          case atomics:compare_exchange(Pending, 1, 0, 1) of
            ok -> gen_server:cast(?SERVER, evict_now);
            _ -> ok
          end
      end;
    _ ->
      ok
  end.

%% @doc Sets the buffer size (for testing). Takes effect immediately.
-spec set_buffer_size(pos_integer()) -> ok.
set_buffer_size(Size) when is_integer(Size), Size > 0 ->
  gen_server:call(?SERVER, {set_buffer_size, Size}).

%% ============================================================================
%% gen_server callbacks
%% ============================================================================

init(_Args) ->
  BufferSize = instrument_lib:bounded_env(flight_recorder_buffer_size,
                                          ?DEFAULT_BUFFER_SIZE, 1, 1 bsl 30),
  AutoEnable = application:get_env(instrument, flight_recorder_auto_enable, false),
  persistent_term:put(?BUFFER_LIMIT_KEY, BufferSize),
  case persistent_term:get(?EVICT_PENDING_KEY, undefined) of
    undefined -> persistent_term:put(?EVICT_PENDING_KEY, atomics:new(1, []));
    Pending -> atomics:put(Pending, 1, 0)
  end,

  %% Create ETS table for ring buffer
  ets:new(?BUFFER_TABLE, [
    named_table,
    ordered_set,
    public,
    {write_concurrency, true}
  ]),

  %% The tracer pool supervisor is started before us by instrument_sup.
  State = #state{buffer_size = BufferSize},

  case AutoEnable =:= true of
    true ->
      instrument_tracer_pool:start_pool(),
      persistent_term:put(?ENABLED_KEY, true);
    false ->
      persistent_term:put(?ENABLED_KEY, false)
  end,

  %% Schedule periodic eviction check
  erlang:send_after(1000, self(), check_eviction),

  {ok, State}.

handle_call(enable, _From, State) ->
  instrument_tracer_pool:start_pool(),
  persistent_term:put(?ENABLED_KEY, true),
  {reply, ok, State};

handle_call(disable, _From, State) ->
  instrument_tracer_pool:stop_pool(),
  persistent_term:put(?ENABLED_KEY, false),
  {reply, ok, State};

handle_call(clear, _From, State) ->
  ets:delete_all_objects(?BUFFER_TABLE),
  {reply, ok, State};

handle_call(stats, _From, #state{buffer_size = BufferSize} = State) ->
  TableSize = instrument_lib:safe_apply(ets, info, [?BUFFER_TABLE, size], 0),
  #{dropped := Dropped, queued := Queued, max := MaxQueue} =
    instrument_tracer_pool:stats(),
  Stats = #{
    enabled => is_enabled(),
    buffer_size => BufferSize,
    table_size => TableSize,
    pool_size => instrument_tracer_pool:pool_size(),
    dropped_events => Dropped,
    queued_events => Queued,
    max_queue => MaxQueue,
    max_payload_bytes => instrument_flight_tracer:max_payload()
  },
  {reply, Stats, State};

handle_call({set_buffer_size, Size}, _From, State) ->
  persistent_term:put(?BUFFER_LIMIT_KEY, Size),
  {reply, ok, State#state{buffer_size = Size}};

handle_call(_Request, _From, State) ->
  {reply, {error, unknown_call}, State}.

handle_cast(evict_now, State) ->
  trim(State),
  case persistent_term:get(?EVICT_PENDING_KEY, undefined) of
    undefined -> ok;
    Pending -> atomics:put(Pending, 1, 0)
  end,
  {noreply, State};

handle_cast(_Msg, State) ->
  {noreply, State}.

%% Periodic eviction check
handle_info(check_eviction, State) ->
  trim(State),
  erlang:send_after(1000, self(), check_eviction),
  {noreply, State};

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  %% Stop the pool
  instrument_lib:safe_apply(instrument_tracer_pool, stop_pool, [], ok),
  persistent_term:put(?ENABLED_KEY, false),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% ============================================================================
%% Internal Functions
%% ============================================================================

%% @private Get current trace label from process dict or tracer state.
%% For spawned children that inherit tracing via set_on_spawn, the label
%% is not in process dict but can be extracted from the tracer state.
get_current_label() ->
  case get(?LABEL_KEY) of
    undefined ->
      %% Try to get label from tracer state (for spawned children)
      extract_label_from_tracer();
    Label ->
      Label
  end.

%% @private Extract label from tracer state if available.
%% Note: dialyzer's type spec for trace_info is incomplete, so we use
%% try/catch to safely extract the label from the tracer state tuple.
-dialyzer({nowarn_function, extract_label_from_tracer/0}).
extract_label_from_tracer() ->
  try
    case erlang:trace_info(self(), tracer) of
      {tracer, {instrument_tracer_nif, TracerState}} when is_map(TracerState) ->
        maps:get(label, TracerState, undefined);
      _ ->
        undefined
    end
  catch
    Class:Reason:Stack ->
      logger:debug("Failed to extract label from tracer: ~p:~p~n~p",
                   [Class, Reason, Stack]),
      undefined
  end.

%% @private Trim the buffer back to its limit.
trim(#state{buffer_size = Max}) ->
  TableSize = instrument_lib:safe_apply(ets, info, [?BUFFER_TABLE, size], 0),
  case is_integer(TableSize) andalso TableSize > Max of
    true -> evict_oldest(TableSize - Max);
    false -> ok
  end.

%% @private Evicts N oldest entries from the buffer.
%% Uses batch selection for better performance on large evictions.
evict_oldest(0) ->
  ok;
evict_oldest(N) when N > 0 ->
  %% Select N oldest keys using ordered_set property (keys are in order)
  %% ets:select with limit is more efficient than repeated first/delete
  MatchSpec = [{{'$1', '_', '_'}, [], ['$1']}],
  case ets:select(?BUFFER_TABLE, MatchSpec, N) of
    {Keys, _Continuation} ->
      %% Delete all selected keys
      lists:foreach(fun(Key) -> ets:delete(?BUFFER_TABLE, Key) end, Keys);
    '$end_of_table' ->
      ok
  end.
