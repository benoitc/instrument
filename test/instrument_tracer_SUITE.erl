%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_tracer_SUITE).
-author("benoitc").

-export([
  all/0,
  init_per_suite/1,
  end_per_suite/1,
  init_per_testcase/2,
  end_per_testcase/2
]).

-export([
  get_tracer/1,
  start_and_end_span/1,
  with_span/1,
  with_span_exception/1,
  nested_spans/1,
  span_attributes/1,
  span_events/1,
  span_status/1,
  span_context/1,
  trace_id_generation/1,
  span_exporter/1,
  propagation_across_processes/1,
  spans_no_context_leak/1,
  tracing_disabled/1,
  custom_span_id/1,
  concurrent_exporter_registration/1,
  record_only_no_export_test/1
]).

-include("instrument_otel.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
  [
    get_tracer,
    start_and_end_span,
    with_span,
    with_span_exception,
    nested_spans,
    span_attributes,
    span_events,
    span_status,
    span_context,
    trace_id_generation,
    span_exporter,
    propagation_across_processes,
    spans_no_context_leak,
    tracing_disabled,
    custom_span_id,
    concurrent_exporter_registration,
    record_only_no_export_test
  ].

init_per_suite(Config) ->
  %% crypto might already be started
  _ = application:ensure_all_started(crypto),
  ok = application:start(instrument),
  Config.

end_per_suite(Config) ->
  ok = application:stop(instrument),
  Config.

init_per_testcase(_, Config) ->
  %% Clean up context between tests
  erlang:erase('$instrument_context'),
  Config.

end_per_testcase(_, _Config) ->
  erlang:erase('$instrument_context'),
  ok.

%% ============================================================================
%% Tracer Tests
%% ============================================================================

get_tracer(_Config) ->
  Tracer = instrument_tracer:get_tracer(<<"my_service">>),
  #tracer{name = <<"my_service">>} = Tracer,

  Tracer2 = instrument_tracer:get_tracer(my_service, #{version => <<"1.0.0">>}),
  #tracer{name = <<"my_service">>, version = <<"1.0.0">>} = Tracer2,
  ok.

start_and_end_span(_Config) ->
  %% No current span initially
  undefined = instrument_tracer:current_span(),

  %% Start span
  Span = instrument_tracer:start_span(<<"test_span">>),
  #span{name = <<"test_span">>} = Span,

  %% Current span should be set
  CurrentSpan = instrument_tracer:current_span(),
  #span{name = <<"test_span">>} = CurrentSpan,

  %% Span should be recording
  true = instrument_tracer:is_recording(),

  %% End span
  ok = instrument_tracer:end_span(),

  %% No current span after end
  undefined = instrument_tracer:current_span(),
  ok.

with_span(_Config) ->
  Result = instrument_tracer:with_span(<<"my_operation">>, fun() ->
    %% Should have a current span
    Span = instrument_tracer:current_span(),
    #span{name = <<"my_operation">>} = Span,
    computed_result
  end),
  computed_result = Result,

  %% No span after with_span returns
  undefined = instrument_tracer:current_span(),
  ok.

with_span_exception(_Config) ->
  try
    instrument_tracer:with_span(<<"failing_operation">>, fun() ->
      throw(my_error)
    end),
    ct:fail(should_have_thrown)
  catch
    throw:my_error ->
      %% Expected
      ok
  end,

  %% Span should be ended even after exception
  undefined = instrument_tracer:current_span(),
  ok.

nested_spans(_Config) ->
  instrument_tracer:with_span(<<"parent">>, fun() ->
    ParentCtx = instrument_tracer:span_ctx(),
    ParentSpan = instrument_tracer:current_span(),

    instrument_tracer:with_span(<<"child">>, fun() ->
      ChildSpan = instrument_tracer:current_span(),
      #span{parent_ctx = ParentCtx} = ChildSpan,

      %% Should have same trace_id
      #span_ctx{trace_id = TraceId} = ParentCtx,
      #span_ctx{trace_id = TraceId} = ChildSpan#span.ctx,

      %% But different span_id
      #span_ctx{span_id = ParentSpanId} = ParentCtx,
      #span_ctx{span_id = ChildSpanId} = ChildSpan#span.ctx,
      true = ParentSpanId =/= ChildSpanId
    end),

    %% After child ends, parent span should be restored (not undefined)
    RestoredSpan = instrument_tracer:current_span(),
    ?assertNotEqual(undefined, RestoredSpan),
    ?assertEqual(<<"parent">>, RestoredSpan#span.name),
    ?assertEqual(ParentSpan#span.ctx, RestoredSpan#span.ctx),

    %% Test deeply nested spans
    instrument_tracer:with_span(<<"child2">>, fun() ->
      instrument_tracer:with_span(<<"grandchild">>, fun() ->
        GrandchildSpan = instrument_tracer:current_span(),
        ?assertEqual(<<"grandchild">>, GrandchildSpan#span.name)
      end),
      %% After grandchild ends, child2 should be current
      AfterGrandchild = instrument_tracer:current_span(),
      ?assertNotEqual(undefined, AfterGrandchild),
      ?assertEqual(<<"child2">>, AfterGrandchild#span.name)
    end),

    %% After child2 ends, parent should be current again
    AfterChild2 = instrument_tracer:current_span(),
    ?assertNotEqual(undefined, AfterChild2),
    ?assertEqual(<<"parent">>, AfterChild2#span.name)
  end),
  ok.

span_attributes(_Config) ->
  instrument_tracer:with_span(<<"test">>, fun() ->
    %% Set single attribute
    ok = instrument_tracer:set_attribute(<<"key1">>, <<"value1">>),

    %% Set multiple attributes
    ok = instrument_tracer:set_attributes(#{
      <<"key2">> => 42,
      <<"key3">> => true
    }),

    Span = instrument_tracer:current_span(),
    Attrs = Span#span.attributes,
    <<"value1">> = maps:get(<<"key1">>, Attrs),
    42 = maps:get(<<"key2">>, Attrs),
    true = maps:get(<<"key3">>, Attrs)
  end),
  ok.

span_events(_Config) ->
  instrument_tracer:with_span(<<"test">>, fun() ->
    %% Add simple event
    ok = instrument_tracer:add_event(<<"event1">>),

    %% Add event with attributes
    ok = instrument_tracer:add_event(<<"event2">>, #{<<"key">> => <<"value">>}),

    Span = instrument_tracer:current_span(),
    [Event1, Event2] = Span#span.events,
    <<"event1">> = Event1#span_event.name,
    <<"event2">> = Event2#span_event.name,
    #{<<"key">> := <<"value">>} = Event2#span_event.attributes
  end),
  ok.

span_status(_Config) ->
  instrument_tracer:with_span(<<"test">>, fun() ->
    Span1 = instrument_tracer:current_span(),
    unset = Span1#span.status,

    ok = instrument_tracer:set_status(ok),
    Span2 = instrument_tracer:current_span(),
    ok = Span2#span.status,

    ok = instrument_tracer:set_status(error, <<"something went wrong">>),
    Span3 = instrument_tracer:current_span(),
    {error, <<"something went wrong">>} = Span3#span.status
  end),
  ok.

span_context(_Config) ->
  %% No span context initially
  undefined = instrument_tracer:span_ctx(),
  undefined = instrument_tracer:trace_id(),
  undefined = instrument_tracer:span_id(),
  false = instrument_tracer:is_recording(),
  false = instrument_tracer:is_sampled(),

  instrument_tracer:with_span(<<"test">>, fun() ->
    SpanCtx = instrument_tracer:span_ctx(),
    #span_ctx{} = SpanCtx,

    TraceId = instrument_tracer:trace_id(),
    32 = byte_size(TraceId),

    SpanId = instrument_tracer:span_id(),
    16 = byte_size(SpanId),

    true = instrument_tracer:is_recording(),
    true = instrument_tracer:is_sampled()
  end),
  ok.

trace_id_generation(_Config) ->
  %% Generate IDs
  TraceId1 = instrument_id:generate_trace_id(),
  TraceId2 = instrument_id:generate_trace_id(),
  16 = byte_size(TraceId1),
  16 = byte_size(TraceId2),
  true = TraceId1 =/= TraceId2,

  SpanId1 = instrument_id:generate_span_id(),
  SpanId2 = instrument_id:generate_span_id(),
  8 = byte_size(SpanId1),
  8 = byte_size(SpanId2),
  true = SpanId1 =/= SpanId2,

  %% Hex conversion
  TraceIdHex = instrument_id:trace_id_to_hex(TraceId1),
  32 = byte_size(TraceIdHex),
  TraceId1 = instrument_id:hex_to_trace_id(TraceIdHex),

  SpanIdHex = instrument_id:span_id_to_hex(SpanId1),
  16 = byte_size(SpanIdHex),
  SpanId1 = instrument_id:hex_to_span_id(SpanIdHex),

  %% Validation
  true = instrument_id:is_valid_trace_id(TraceId1),
  false = instrument_id:is_valid_trace_id(<<0:128>>),
  false = instrument_id:is_valid_trace_id(undefined),

  true = instrument_id:is_valid_span_id(SpanId1),
  false = instrument_id:is_valid_span_id(<<0:64>>),
  false = instrument_id:is_valid_span_id(undefined),
  ok.

span_exporter(_Config) ->
  Parent = self(),
  Exporter = fun(Span) ->
    Parent ! {exported, Span}
  end,

  ok = instrument_tracer:register_exporter(Exporter),

  instrument_tracer:with_span(<<"exported_span">>, fun() ->
    ok = instrument_tracer:set_status(ok)
  end),

  receive
    {exported, #span{name = <<"exported_span">>}} ->
      ok
  after 1000 ->
    ct:fail(no_export_received)
  end,

  ok = instrument_tracer:unregister_exporter(Exporter),
  ok.

propagation_across_processes(_Config) ->
  Parent = self(),

  instrument_tracer:with_span(<<"parent_span">>, fun() ->
    ParentTraceId = instrument_tracer:trace_id(),

    Pid = instrument_propagation:spawn(fun() ->
      %% Should inherit trace context
      TraceId = instrument_tracer:trace_id(),
      Parent ! {child, TraceId}
    end),

    receive
      {child, ParentTraceId} ->
        %% Same trace ID
        _ = Pid,
        ok
    after 1000 ->
      ct:fail(timeout)
    end
  end),
  ok.

spans_no_context_leak(_Config) ->
  %% Count context entries before
  BeforeCount = count_context_entries(),

  %% Create and end many spans - should NOT leak context entries
  lists:foreach(fun(N) ->
    instrument_tracer:with_span(list_to_binary("span_" ++ integer_to_list(N)), fun() ->
      %% Do some operations that update context
      ok = instrument_tracer:set_attribute(<<"iteration">>, N),
      ok = instrument_tracer:add_event(<<"test_event">>),
      ok = instrument_tracer:set_status(ok)
    end)
  end, lists:seq(1, 100)),

  %% Count context entries after
  AfterCount = count_context_entries(),

  %% Should have at most 1 entry (the main context key)
  %% With the leak, each span would leave behind a token entry
  ct:pal("Context entries before: ~p, after: ~p", [BeforeCount, AfterCount]),
  true = AfterCount =< 1,

  %% Also test nested spans don't leak
  BeforeNested = count_context_entries(),

  instrument_tracer:with_span(<<"outer">>, fun() ->
    instrument_tracer:with_span(<<"middle">>, fun() ->
      instrument_tracer:with_span(<<"inner">>, fun() ->
        ok = instrument_tracer:set_attribute(<<"level">>, 3)
      end),
      ok = instrument_tracer:set_attribute(<<"level">>, 2)
    end),
    ok = instrument_tracer:set_attribute(<<"level">>, 1)
  end),

  AfterNested = count_context_entries(),
  ct:pal("Nested context entries before: ~p, after: ~p", [BeforeNested, AfterNested]),
  true = AfterNested =< 1,
  ok.

count_context_entries() ->
  Dict = erlang:get(),
  length([K || {K, _} <- Dict, is_context_key(K)]).

is_context_key('$instrument_context') -> true;
is_context_key({'$instrument_context', _}) -> true;
is_context_key(_) -> false.

tracing_disabled(_Config) ->
  %% Ensure tracing is enabled initially
  true = instrument_config:is_tracing_enabled(),

  %% Disable tracing
  ok = instrument_config:set_tracing_enabled(false),

  try
    %% Create span when disabled - should return noop span
    NoopSpan = instrument_tracer:start_span(<<"noop_test">>),
    #span{name = <<"noop_test">>, is_recording = false} = NoopSpan,

    %% Span should have zero IDs
    #span{ctx = #span_ctx{trace_id = <<0:128>>, span_id = <<0:64>>}} = NoopSpan,

    %% with_span should still execute the function
    Result = instrument_tracer:with_span(<<"disabled_span">>, fun() ->
      %% Operations on non-recording span are no-ops
      ok = instrument_tracer:set_attribute(<<"key">>, <<"value">>),
      computed_value
    end),
    computed_value = Result,

    %% Span should still be available as current
    instrument_tracer:with_span(<<"test">>, fun() ->
      CurrentSpan = instrument_tracer:current_span(),
      #span{is_recording = false} = CurrentSpan
    end),

    %% No span after with_span returns
    undefined = instrument_tracer:current_span()
  after
    %% Re-enable tracing
    ok = instrument_config:set_tracing_enabled(true)
  end,

  %% Verify tracing works again after re-enabling
  instrument_tracer:with_span(<<"enabled_span">>, fun() ->
    EnabledSpan = instrument_tracer:current_span(),
    #span{is_recording = true} = EnabledSpan,
    %% Should have non-zero IDs
    #span{ctx = #span_ctx{trace_id = TraceId, span_id = SpanId}} = EnabledSpan,
    true = TraceId =/= <<0:128>>,
    true = SpanId =/= <<0:64>>
  end),
  ok.

custom_span_id(_Config) ->
  %% Test with 8-byte binary span_id
  CustomSpanId = crypto:strong_rand_bytes(8),
  instrument_tracer:with_span(<<"custom_id_test">>, #{span_id => CustomSpanId}, fun() ->
    SpanIdHex = instrument_tracer:span_id(),
    ExpectedHex = instrument_id:span_id_to_hex(CustomSpanId),
    ExpectedHex = SpanIdHex
  end),

  %% Test with 16-char hex string span_id
  HexSpanId = <<"abcd1234abcd1234">>,
  instrument_tracer:with_span(<<"hex_id_test">>, #{span_id => HexSpanId}, fun() ->
    SpanIdHex = instrument_tracer:span_id(),
    HexSpanId = SpanIdHex
  end),

  %% Verify auto-generated IDs still work
  instrument_tracer:with_span(<<"auto_id_test">>, fun() ->
    SpanId = instrument_tracer:span_id(),
    16 = byte_size(SpanId),
    %% Should not be our custom IDs
    true = SpanId =/= instrument_id:span_id_to_hex(CustomSpanId),
    true = SpanId =/= HexSpanId
  end),
  ok.

concurrent_exporter_registration(_Config) ->
  %% Test concurrent registration and unregistration of exporters
  Parent = self(),
  NumProcesses = 50,

  %% Create unique exporters for each process
  Exporters = [fun(_Span) -> ok end || _ <- lists:seq(1, NumProcesses)],

  %% Spawn processes that register exporters concurrently
  Pids = [spawn_link(fun() ->
    Exporter = lists:nth(N, Exporters),
    ok = instrument_tracer:register_exporter(Exporter),
    Parent ! {registered, self(), Exporter}
  end) || N <- lists:seq(1, NumProcesses)],

  %% Collect results
  RegisteredExporters = [receive
    {registered, Pid, Exporter} -> Exporter
  after 5000 ->
    ct:fail({timeout_waiting_for, Pid})
  end || Pid <- Pids],

  %% Verify all exporters were registered (no duplicates lost)
  CurrentExporters = [E || {exporter, E} <- ets:tab2list(instrument_span_exporters)],
  lists:foreach(fun(E) ->
    true = lists:member(E, CurrentExporters)
  end, RegisteredExporters),

  %% Now test concurrent unregistration
  UnregPids = [spawn_link(fun() ->
    Exporter = lists:nth(N, Exporters),
    ok = instrument_tracer:unregister_exporter(Exporter),
    Parent ! {unregistered, self()}
  end) || N <- lists:seq(1, NumProcesses)],

  %% Wait for all unregistrations
  lists:foreach(fun(Pid) ->
    receive {unregistered, Pid} -> ok
    after 5000 -> ct:fail({timeout_waiting_for, Pid})
    end
  end, UnregPids),

  %% Verify all exporters were unregistered
  FinalExporters = [E || {exporter, E} <- ets:tab2list(instrument_span_exporters)],
  lists:foreach(fun(E) ->
    false = lists:member(E, FinalExporters)
  end, RegisteredExporters),

  ok.

%% Test that spans with trace_flags=0 (record_only) are NOT exported
record_only_no_export_test(_Config) ->
  %% Save original sampler and set parent-based sampler
  OriginalSampler = instrument_sampler:get_sampler(),
  ok = instrument_sampler:set_sampler(instrument_sampler_parent_based, #{}),

  Parent = self(),
  Exporter = fun(Span) ->
    Parent ! {exported, Span}
  end,
  ok = instrument_tracer:register_exporter(Exporter),

  try
    %% Create a custom parent with trace_flags=0 (not sampled)
    TraceId = instrument_id:generate_trace_id(),
    ParentCtx = #span_ctx{
      trace_id = TraceId,
      span_id = instrument_id:generate_span_id(),
      trace_flags = 0,  %% not sampled - should NOT be exported
      is_remote = false
    },

    %% Start span with this parent context
    Span = instrument_tracer:start_span(<<"record_only_span">>, #{parent => ParentCtx}),

    %% Span should inherit trace_flags=0 from unsampled parent
    ?assertEqual(0, (Span#span.ctx)#span_ctx.trace_flags),

    instrument_tracer:end_span(Span),

    %% Should NOT receive export message for non-sampled span
    receive
      {exported, #span{name = <<"record_only_span">>}} ->
        ct:fail(should_not_export_record_only_span)
    after 100 ->
      %% Expected: no export
      ok
    end
  after
    ok = instrument_tracer:unregister_exporter(Exporter),
    %% Restore original sampler
    ok = instrument_sampler:set_sampler(OriginalSampler, #{})
  end,
  ok.
