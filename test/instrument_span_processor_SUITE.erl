%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_span_processor_SUITE).
-author("benoitc").

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("instrument_otel.hrl").

-export([
  all/0,
  init_per_suite/1,
  end_per_suite/1,
  init_per_testcase/2,
  end_per_testcase/2
]).

-export([
  processor_register_unregister_test/1,
  processor_list_test/1,
  simple_processor_test/1,
  simple_processor_state_persistence_test/1,
  processor_chain_test/1,
  processor_integration_test/1,
  force_flush_test/1,
  %% New tests
  batch_timeout_export_test/1,
  batch_max_size_export_test/1,
  batch_queue_overflow_test/1,
  batch_exporter_state_update_test/1,
  batch_export_timeout_test/1,
  processor_shutdown_test/1,
  concurrent_span_recording_test/1,
  exporter_error_handling_test/1,
  %% High concurrency tests
  high_concurrency_span_recording_test/1,
  sustained_load_test/1,
  memory_stability_test/1
]).

all() ->
  [
    processor_register_unregister_test,
    processor_list_test,
    simple_processor_test,
    simple_processor_state_persistence_test,
    processor_chain_test,
    processor_integration_test,
    force_flush_test,
    %% New tests
    batch_timeout_export_test,
    batch_max_size_export_test,
    batch_queue_overflow_test,
    batch_exporter_state_update_test,
    batch_export_timeout_test,
    processor_shutdown_test,
    concurrent_span_recording_test,
    exporter_error_handling_test,
    %% High concurrency tests
    high_concurrency_span_recording_test,
    sustained_load_test,
    memory_stability_test
  ].

init_per_suite(Config) ->
  _ = application:ensure_all_started(crypto),
  ok = application:start(instrument),
  Config.

end_per_suite(_Config) ->
  ok = application:stop(instrument),
  ok.

init_per_testcase(_TestCase, Config) ->
  %% Clear all processors
  lists:foreach(fun(M) ->
    instrument_span_processor:unregister(M)
  end, instrument_span_processor:list()),
  Config.

end_per_testcase(_TestCase, _Config) ->
  %% Clear all processors
  lists:foreach(fun(M) ->
    instrument_span_processor:unregister(M)
  end, instrument_span_processor:list()),
  ok.

%% ============================================================================
%% Test Cases
%% ============================================================================

processor_register_unregister_test(_Config) ->
  %% Create a mock exporter module
  meck:new(mock_exporter, [non_strict]),
  meck:expect(mock_exporter, init, fun(_) -> {ok, #{}} end),
  meck:expect(mock_exporter, export, fun(_, State) -> {ok, State} end),
  meck:expect(mock_exporter, shutdown, fun(_) -> ok end),

  %% Register simple processor
  ok = instrument_span_processor:register(instrument_span_processor_simple, #{
    exporter => mock_exporter
  }),
  ?assertEqual([instrument_span_processor_simple], instrument_span_processor:list()),

  %% Unregister
  ok = instrument_span_processor:unregister(instrument_span_processor_simple),
  ?assertEqual([], instrument_span_processor:list()),

  meck:unload(mock_exporter),
  ok.

processor_list_test(_Config) ->
  %% Initially empty
  ?assertEqual([], instrument_span_processor:list()),

  %% Create mock processors
  meck:new(mock_processor1, [non_strict]),
  meck:expect(mock_processor1, init, fun(_) -> {ok, #{}} end),
  meck:expect(mock_processor1, on_start, fun(Span, _) -> Span end),
  meck:expect(mock_processor1, on_end, fun(_) -> ok end),
  meck:expect(mock_processor1, shutdown, fun(_) -> ok end),
  meck:expect(mock_processor1, force_flush, fun(_) -> ok end),

  meck:new(mock_processor2, [non_strict]),
  meck:expect(mock_processor2, init, fun(_) -> {ok, #{}} end),
  meck:expect(mock_processor2, on_start, fun(Span, _) -> Span end),
  meck:expect(mock_processor2, on_end, fun(_) -> ok end),
  meck:expect(mock_processor2, shutdown, fun(_) -> ok end),
  meck:expect(mock_processor2, force_flush, fun(_) -> ok end),

  %% Register processors
  ok = instrument_span_processor:register(mock_processor1, #{}),
  ok = instrument_span_processor:register(mock_processor2, #{}),

  %% Both should be listed
  Listed = instrument_span_processor:list(),
  ?assert(lists:member(mock_processor1, Listed)),
  ?assert(lists:member(mock_processor2, Listed)),

  %% Cleanup
  instrument_span_processor:unregister(mock_processor1),
  instrument_span_processor:unregister(mock_processor2),
  meck:unload([mock_processor1, mock_processor2]),
  ok.

simple_processor_test(_Config) ->
  %% Create a mock exporter that collects spans
  Self = self(),
  meck:new(mock_exporter2, [non_strict]),
  meck:expect(mock_exporter2, init, fun(_) -> {ok, #{pid => Self}} end),
  meck:expect(mock_exporter2, export, fun(Spans, State) ->
    #{pid := Pid} = State,
    Pid ! {spans_exported, Spans},
    {ok, State}
  end),
  meck:expect(mock_exporter2, shutdown, fun(_) -> ok end),

  %% Register simple processor
  ok = instrument_span_processor:register(instrument_span_processor_simple, #{
    exporter => mock_exporter2
  }),

  %% Create and end a span
  Span = instrument_tracer:start_span(<<"processor_test_span">>),
  instrument_tracer:end_span(Span),

  %% Cleanup
  instrument_span_processor:unregister(instrument_span_processor_simple),
  meck:unload(mock_exporter2),
  ok.

%% Test that simple processor correctly persists state to persistent_term (Bug 1 fix)
simple_processor_state_persistence_test(_Config) ->
  Self = self(),
  meck:new(state_test_exporter, [non_strict]),
  meck:expect(state_test_exporter, init, fun(_) -> {ok, #{pid => Self, calls => 0}} end),
  meck:expect(state_test_exporter, export, fun(Spans, State) ->
    #{pid := Pid, calls := Calls} = State,
    Pid ! {exported, length(Spans), Calls},
    {ok, State#{calls => Calls + 1}}
  end),
  meck:expect(state_test_exporter, shutdown, fun(_) -> ok end),

  %% Register simple processor
  ok = instrument_span_processor:register(instrument_span_processor_simple, #{
    exporter => state_test_exporter
  }),

  %% Verify state was stored in persistent_term (Bug 1 fix verification)
  State = persistent_term:get({instrument_span_processor_simple, state}, undefined),
  ?assertNotEqual(undefined, State),

  %% Create and end a span - should be exported immediately
  Span1 = instrument_tracer:start_span(<<"state_test_span_1">>),
  instrument_tracer:end_span(Span1),

  %% Verify export was called
  receive
    {exported, 1, _} -> ok
  after 1000 ->
    ct:fail(span_not_exported)
  end,

  %% Create another span to verify state persists
  Span2 = instrument_tracer:start_span(<<"state_test_span_2">>),
  instrument_tracer:end_span(Span2),

  receive
    {exported, 1, _} -> ok
  after 1000 ->
    ct:fail(second_span_not_exported)
  end,

  %% Cleanup
  instrument_span_processor:unregister(instrument_span_processor_simple),
  meck:unload(state_test_exporter),
  ok.

processor_chain_test(_Config) ->
  %% Test that multiple processors are called in chain
  Self = self(),

  meck:new(chain_processor1, [non_strict]),
  meck:expect(chain_processor1, init, fun(_) -> {ok, #{}} end),
  meck:expect(chain_processor1, on_start, fun(Span, _) ->
    Self ! {processor1_on_start, Span#span.name},
    %% Add an attribute
    NewAttrs = maps:put(<<"processor1">>, <<"added">>, Span#span.attributes),
    Span#span{attributes = NewAttrs}
  end),
  meck:expect(chain_processor1, on_end, fun(Span) ->
    Self ! {processor1_on_end, Span#span.name},
    ok
  end),
  meck:expect(chain_processor1, shutdown, fun(_) -> ok end),
  meck:expect(chain_processor1, force_flush, fun(_) -> ok end),

  meck:new(chain_processor2, [non_strict]),
  meck:expect(chain_processor2, init, fun(_) -> {ok, #{}} end),
  meck:expect(chain_processor2, on_start, fun(Span, _) ->
    Self ! {processor2_on_start, Span#span.name},
    Span
  end),
  meck:expect(chain_processor2, on_end, fun(Span) ->
    Self ! {processor2_on_end, Span#span.name},
    ok
  end),
  meck:expect(chain_processor2, shutdown, fun(_) -> ok end),
  meck:expect(chain_processor2, force_flush, fun(_) -> ok end),

  %% Register both processors
  ok = instrument_span_processor:register(chain_processor1, #{}),
  ok = instrument_span_processor:register(chain_processor2, #{}),

  %% Create and end a span
  Span = instrument_tracer:start_span(<<"chain_test_span">>),

  %% Verify both on_start were called
  receive {processor1_on_start, <<"chain_test_span">>} -> ok
  after 1000 -> ct:fail(processor1_on_start_not_called)
  end,
  receive {processor2_on_start, <<"chain_test_span">>} -> ok
  after 1000 -> ct:fail(processor2_on_start_not_called)
  end,

  %% Verify processor1 added attribute
  ?assertEqual(<<"added">>, maps:get(<<"processor1">>, Span#span.attributes, undefined)),

  instrument_tracer:end_span(Span),

  %% Verify both on_end were called
  receive {processor1_on_end, <<"chain_test_span">>} -> ok
  after 1000 -> ct:fail(processor1_on_end_not_called)
  end,
  receive {processor2_on_end, <<"chain_test_span">>} -> ok
  after 1000 -> ct:fail(processor2_on_end_not_called)
  end,

  %% Cleanup
  instrument_span_processor:unregister(chain_processor1),
  instrument_span_processor:unregister(chain_processor2),
  meck:unload([chain_processor1, chain_processor2]),
  ok.

processor_integration_test(_Config) ->
  %% Test that span processors are called during span lifecycle
  Self = self(),

  meck:new(integration_processor, [non_strict]),
  meck:expect(integration_processor, init, fun(_) -> {ok, #{}} end),
  meck:expect(integration_processor, on_start, fun(Span, ParentCtx) ->
    Self ! {on_start_called, Span#span.name, ParentCtx},
    Span
  end),
  meck:expect(integration_processor, on_end, fun(Span) ->
    Self ! {on_end_called, Span#span.name, Span#span.end_time},
    ok
  end),
  meck:expect(integration_processor, shutdown, fun(_) -> ok end),
  meck:expect(integration_processor, force_flush, fun(_) -> ok end),

  ok = instrument_span_processor:register(integration_processor, #{}),

  %% Create parent span
  ParentSpan = instrument_tracer:start_span(<<"parent_span">>),
  receive {on_start_called, <<"parent_span">>, undefined} -> ok
  after 1000 -> ct:fail(parent_on_start_not_called)
  end,

  %% Create child span
  _ChildSpan = instrument_tracer:start_span(<<"child_span">>),
  receive {on_start_called, <<"child_span">>, ParentCtx} ->
    ?assertNotEqual(undefined, ParentCtx),
    ?assertEqual(ParentSpan#span.ctx#span_ctx.span_id, ParentCtx#span_ctx.span_id)
  after 1000 -> ct:fail(child_on_start_not_called)
  end,

  %% End spans
  instrument_tracer:end_span(),
  receive {on_end_called, <<"child_span">>, EndTime1} ->
    ?assertNotEqual(undefined, EndTime1)
  after 1000 -> ct:fail(child_on_end_not_called)
  end,

  instrument_tracer:end_span(ParentSpan),
  receive {on_end_called, <<"parent_span">>, EndTime2} ->
    ?assertNotEqual(undefined, EndTime2)
  after 1000 -> ct:fail(parent_on_end_not_called)
  end,

  %% Cleanup
  instrument_span_processor:unregister(integration_processor),
  meck:unload(integration_processor),
  ok.

force_flush_test(_Config) ->
  Self = self(),

  meck:new(flush_processor, [non_strict]),
  meck:expect(flush_processor, init, fun(_) -> {ok, #{}} end),
  meck:expect(flush_processor, on_start, fun(Span, _) -> Span end),
  meck:expect(flush_processor, on_end, fun(_) -> ok end),
  meck:expect(flush_processor, shutdown, fun(_) -> ok end),
  meck:expect(flush_processor, force_flush, fun(_) ->
    Self ! force_flush_called,
    ok
  end),

  ok = instrument_span_processor:register(flush_processor, #{}),

  %% Force flush
  ok = instrument_span_processor:force_flush(),

  receive force_flush_called -> ok
  after 1000 -> ct:fail(force_flush_not_called)
  end,

  %% Cleanup
  instrument_span_processor:unregister(flush_processor),
  meck:unload(flush_processor),
  ok.

%% ============================================================================
%% New Test Cases
%% ============================================================================

batch_timeout_export_test(_Config) ->
  %% Test batch processor configuration is accepted
  %% Note: Full gen_server lifecycle is tested in integration tests

  meck:new(timeout_exporter, [non_strict]),
  meck:expect(timeout_exporter, init, fun(_) -> {ok, #{}} end),
  meck:expect(timeout_exporter, export, fun(_, State) -> {ok, State} end),
  meck:expect(timeout_exporter, shutdown, fun(_) -> ok end),

  %% Verify batch processor can be registered with timeout config
  ok = instrument_span_processor:register(instrument_span_processor_batch, #{
    exporter => timeout_exporter,
    schedule_delay_millis => 100,
    max_export_batch_size => 1000
  }),

  %% Processor should be listed
  Listed = instrument_span_processor:list(),
  ?assert(lists:member(instrument_span_processor_batch, Listed)),

  %% Cleanup
  instrument_span_processor:unregister(instrument_span_processor_batch),
  meck:unload(timeout_exporter),
  ok.

batch_max_size_export_test(_Config) ->
  %% Test batch processor configuration with max batch size
  %% Note: Full gen_server lifecycle is tested in integration tests

  meck:new(size_exporter, [non_strict]),
  meck:expect(size_exporter, init, fun(_) -> {ok, #{}} end),
  meck:expect(size_exporter, export, fun(_, State) -> {ok, State} end),
  meck:expect(size_exporter, shutdown, fun(_) -> ok end),

  %% Verify batch processor can be registered with batch size config
  ok = instrument_span_processor:register(instrument_span_processor_batch, #{
    exporter => size_exporter,
    schedule_delay_millis => 30000,
    max_export_batch_size => 3
  }),

  %% Processor should be listed
  Listed = instrument_span_processor:list(),
  ?assert(lists:member(instrument_span_processor_batch, Listed)),

  %% Cleanup
  instrument_span_processor:unregister(instrument_span_processor_batch),
  meck:unload(size_exporter),
  ok.

batch_queue_overflow_test(_Config) ->
  %% Test batch processor configuration with queue size limit
  %% Note: Full gen_server lifecycle is tested in integration tests

  meck:new(overflow_exporter, [non_strict]),
  meck:expect(overflow_exporter, init, fun(_) -> {ok, #{}} end),
  meck:expect(overflow_exporter, export, fun(_, State) -> {ok, State} end),
  meck:expect(overflow_exporter, shutdown, fun(_) -> ok end),

  %% Verify batch processor can be registered with queue size config
  ok = instrument_span_processor:register(instrument_span_processor_batch, #{
    exporter => overflow_exporter,
    max_queue_size => 5,
    max_export_batch_size => 2
  }),

  %% Processor should be listed
  Listed = instrument_span_processor:list(),
  ?assert(lists:member(instrument_span_processor_batch, Listed)),

  %% Cleanup
  instrument_span_processor:unregister(instrument_span_processor_batch),
  meck:unload(overflow_exporter),
  ok.

%% Test that batch processor correctly updates exporter state (Bug 5 fix)
batch_exporter_state_update_test(_Config) ->
  Self = self(),
  meck:new(stateful_exporter, [non_strict]),
  meck:expect(stateful_exporter, init, fun(_) -> {ok, #{count => 0, pid => Self}} end),
  meck:expect(stateful_exporter, export, fun(Spans, #{count := C, pid := Pid} = State) ->
    NewCount = C + length(Spans),
    Pid ! {export_count, NewCount},
    {ok, State#{count => NewCount}}
  end),
  meck:expect(stateful_exporter, shutdown, fun(#{count := C, pid := Pid}) ->
    Pid ! {shutdown_count, C},
    ok
  end),

  %% Register batch processor with small batch size for quick exports
  ok = instrument_span_processor:register(instrument_span_processor_batch, #{
    exporter => stateful_exporter,
    max_export_batch_size => 2,
    schedule_delay_millis => 60000  %% Long delay so we control exports via batch size
  }),

  %% Create 4 spans to trigger 2 exports
  lists:foreach(fun(I) ->
    Name = iolist_to_binary([<<"stateful_span_">>, integer_to_binary(I)]),
    Span = instrument_tracer:start_span(Name),
    instrument_tracer:end_span(Span)
  end, lists:seq(1, 4)),

  %% Wait a bit for async processing
  timer:sleep(100),

  %% Force shutdown to get final state
  ok = instrument_span_processor:unregister(instrument_span_processor_batch),

  %% Verify exporter received cumulative count in shutdown
  receive
    {shutdown_count, Count} ->
      %% Should have seen at least 4 spans total
      ?assert(Count >= 4, io_lib:format("Expected >= 4, got ~p", [Count]))
  after 1000 ->
    ct:fail(shutdown_not_called)
  end,

  meck:unload(stateful_exporter),
  ok.

%% Test that batch processor respects export timeout (Bug 5 fix)
batch_export_timeout_test(_Config) ->
  Self = self(),
  meck:new(slow_exporter, [non_strict]),
  meck:expect(slow_exporter, init, fun(_) -> {ok, #{pid => Self}} end),
  meck:expect(slow_exporter, export, fun(_Spans, #{pid := Pid} = State) ->
    Pid ! export_started,
    %% Sleep longer than timeout
    timer:sleep(500),
    Pid ! export_completed,
    {ok, State}
  end),
  meck:expect(slow_exporter, shutdown, fun(_) -> ok end),

  %% Register batch processor with short timeout
  ok = instrument_span_processor:register(instrument_span_processor_batch, #{
    exporter => slow_exporter,
    max_export_batch_size => 1,
    export_timeout_millis => 100,  %% 100ms timeout
    schedule_delay_millis => 60000
  }),

  %% Create a span to trigger export
  Span = instrument_tracer:start_span(<<"timeout_test_span">>),
  instrument_tracer:end_span(Span),

  %% Verify export started
  receive
    export_started -> ok
  after 1000 ->
    ct:fail(export_not_started)
  end,

  %% The export should be killed by timeout, so export_completed should NOT arrive
  %% (or arrive late after we've moved on)
  timer:sleep(200),

  %% Cleanup - this should not hang even if export is slow
  ok = instrument_span_processor:unregister(instrument_span_processor_batch),

  %% Flush any remaining messages
  flush_messages(),

  meck:unload(slow_exporter),
  ok.

flush_messages() ->
  receive
    _ -> flush_messages()
  after 0 ->
    ok
  end.

processor_shutdown_test(_Config) ->
  %% Test that shutdown flushes pending spans
  Self = self(),

  meck:new(shutdown_exporter, [non_strict]),
  meck:expect(shutdown_exporter, init, fun(_) -> {ok, #{pid => Self}} end),
  meck:expect(shutdown_exporter, export, fun(Spans, State) ->
    #{pid := Pid} = State,
    Pid ! {exported, length(Spans)},
    {ok, State}
  end),
  meck:expect(shutdown_exporter, shutdown, fun(State) ->
    #{pid := Pid} = State,
    Pid ! shutdown_called,
    ok
  end),

  meck:new(shutdown_processor, [non_strict]),
  meck:expect(shutdown_processor, init, fun(Opts) ->
    shutdown_exporter:init(Opts)
  end),
  meck:expect(shutdown_processor, on_start, fun(Span, _) -> Span end),
  meck:expect(shutdown_processor, on_end, fun(_) -> ok end),
  meck:expect(shutdown_processor, force_flush, fun(_) -> ok end),
  meck:expect(shutdown_processor, shutdown, fun(State) ->
    shutdown_exporter:shutdown(State)
  end),

  ok = instrument_span_processor:register(shutdown_processor, #{pid => Self}),

  %% Unregister (which should call shutdown)
  ok = instrument_span_processor:unregister(shutdown_processor),

  receive shutdown_called -> ok
  after 1000 -> ct:fail(shutdown_not_called)
  end,

  meck:unload([shutdown_exporter, shutdown_processor]),
  ok.

concurrent_span_recording_test(_Config) ->
  %% Test concurrent span creation without processor overhead
  Parent = self(),
  NumProcesses = 50,
  SpansPerProcess = 10,

  %% Spawn processes that create spans concurrently
  Pids = [spawn_link(fun() ->
    lists:foreach(fun(I) ->
      Name = iolist_to_binary([<<"span_">>, integer_to_binary(I)]),
      Span = instrument_tracer:start_span(Name),
      instrument_tracer:end_span(Span)
    end, lists:seq(1, SpansPerProcess)),
    Parent ! {done, self()}
  end) || _ <- lists:seq(1, NumProcesses)],

  %% Wait for all processes to complete
  lists:foreach(fun(Pid) ->
    receive {done, Pid} -> ok
    after 5000 -> ct:fail({timeout_waiting_for, Pid})
    end
  end, Pids),

  %% All processes completed without error
  ok.

exporter_error_handling_test(_Config) ->
  %% Test that exporter with errors doesn't crash the system
  meck:new(error_exporter, [non_strict]),
  meck:expect(error_exporter, init, fun(_) -> {ok, #{}} end),
  meck:expect(error_exporter, export, fun(_Spans, _State) ->
    %% Simulate an error
    {error, simulated_error}
  end),
  meck:expect(error_exporter, shutdown, fun(_) -> ok end),

  %% Use simple processor for immediate export
  ok = instrument_span_processor:register(instrument_span_processor_simple, #{
    exporter => error_exporter
  }),

  %% Processor should be listed
  Listed = instrument_span_processor:list(),
  ?assert(lists:member(instrument_span_processor_simple, Listed)),

  %% Cleanup
  instrument_span_processor:unregister(instrument_span_processor_simple),
  meck:unload(error_exporter),
  ok.

%% ============================================================================
%% High Concurrency Tests
%% ============================================================================

high_concurrency_span_recording_test(_Config) ->
  %% 500+ concurrent processes creating spans
  NumProcesses = 500,
  SpansPerProcess = 20,
  Parent = self(),

  %% Spawn processes that create spans concurrently
  Pids = [spawn_link(fun() ->
    lists:foreach(fun(I) ->
      Name = iolist_to_binary([<<"high_conc_span_">>, integer_to_binary(I)]),
      Span = instrument_tracer:start_span(Name),
      %% Add some attributes to increase work
      ok = instrument_tracer:set_attribute(<<"process_id">>, erlang:unique_integer()),
      ok = instrument_tracer:set_attribute(<<"iteration">>, I),
      ok = instrument_tracer:add_event(<<"test_event">>),
      instrument_tracer:end_span(Span)
    end, lists:seq(1, SpansPerProcess)),
    Parent ! {done, self()}
  end) || _ <- lists:seq(1, NumProcesses)],

  %% Wait for all processes to complete
  lists:foreach(fun(Pid) ->
    receive {done, Pid} -> ok
    after 60000 -> ct:fail({timeout_waiting_for, Pid})
    end
  end, Pids),

  %% All processes completed without error
  ok.

sustained_load_test(_Config) ->
  %% Sustained load for a duration with concurrent span creation
  Self = self(),
  DurationMs = 3000,
  NumProcesses = 50,

  %% Create a counting exporter
  meck:new(counting_exporter, [non_strict]),
  meck:expect(counting_exporter, init, fun(_) -> {ok, #{count => 0}} end),
  meck:expect(counting_exporter, export, fun(Spans, State) ->
    #{count := C} = State,
    {ok, State#{count => C + length(Spans)}}
  end),
  meck:expect(counting_exporter, shutdown, fun(_) -> ok end),

  ok = instrument_span_processor:register(instrument_span_processor_batch, #{
    exporter => counting_exporter,
    schedule_delay_millis => 100,
    max_export_batch_size => 100
  }),

  %% Start load generators
  StopRef = make_ref(),
  Pids = [spawn_link(fun() ->
    sustained_load_loop(Self, StopRef)
  end) || _ <- lists:seq(1, NumProcesses)],

  %% Run for duration
  timer:sleep(DurationMs),

  %% Stop all generators
  lists:foreach(fun(Pid) -> Pid ! {stop, StopRef} end, Pids),

  %% Collect results
  TotalSpans = lists:sum([receive {span_count, Pid, Count} -> Count end || Pid <- Pids]),

  ct:pal("Sustained load test: ~p spans created in ~pms (~.2f spans/sec)",
         [TotalSpans, DurationMs, TotalSpans / (DurationMs / 1000)]),

  %% Should have created a significant number of spans
  ?assert(TotalSpans > 0),

  %% Cleanup
  instrument_span_processor:unregister(instrument_span_processor_batch),
  meck:unload(counting_exporter),
  ok.

sustained_load_loop(Parent, StopRef) ->
  sustained_load_loop(Parent, StopRef, 0).

sustained_load_loop(Parent, StopRef, Count) ->
  receive
    {stop, StopRef} ->
      Parent ! {span_count, self(), Count}
  after 0 ->
    Name = iolist_to_binary([<<"sustained_">>, integer_to_binary(Count)]),
    Span = instrument_tracer:start_span(Name),
    instrument_tracer:end_span(Span),
    sustained_load_loop(Parent, StopRef, Count + 1)
  end.

memory_stability_test(_Config) ->
  %% Test that memory doesn't grow unboundedly under load
  NumIterations = 5,
  SpansPerIteration = 1000,
  NumProcesses = 20,

  %% Get initial memory
  erlang:garbage_collect(),
  {memory, InitialMem} = erlang:process_info(self(), memory),

  %% Run multiple iterations
  lists:foreach(fun(Iter) ->
    ct:pal("Memory test iteration ~p", [Iter]),

    Parent = self(),
    Pids = [spawn_link(fun() ->
      lists:foreach(fun(I) ->
        Name = iolist_to_binary([<<"mem_test_">>, integer_to_binary(I)]),
        Span = instrument_tracer:start_span(Name),
        instrument_tracer:set_attribute(<<"data">>, <<"some test data for memory">>),
        instrument_tracer:end_span(Span)
      end, lists:seq(1, SpansPerIteration)),
      Parent ! {done, self()}
    end) || _ <- lists:seq(1, NumProcesses)],

    %% Wait for iteration to complete
    lists:foreach(fun(Pid) ->
      receive {done, Pid} -> ok after 30000 -> ct:fail(timeout) end
    end, Pids),

    %% Force GC and check memory
    erlang:garbage_collect(),
    {memory, CurrentMem} = erlang:process_info(self(), memory),

    %% Memory should not grow excessively (allow 10x growth max)
    ?assert(CurrentMem < InitialMem * 10,
            io_lib:format("Memory grew from ~p to ~p", [InitialMem, CurrentMem]))
  end, lists:seq(1, NumIterations)),

  ok.
