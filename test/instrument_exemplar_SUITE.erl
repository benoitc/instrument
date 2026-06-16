%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_exemplar_SUITE).
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
  %% Reservoir basic tests
  reservoir_new_test/1,
  reservoir_new_custom_size_test/1,
  reservoir_offer_test/1,
  reservoir_sampling_test/1,
  %% Trace context tests
  exemplar_trace_context_test/1,
  exemplar_no_trace_context_test/1,
  %% Collect and reset tests
  reservoir_collect_test/1,
  reservoir_collect_reset_test/1,
  %% ETS-based API tests
  reservoir_ref_test/1,
  reservoir_ref_concurrent_test/1,
  exemplar_reservoir_survives_transient_creator_test/1
]).

all() ->
  [
    %% Reservoir basic tests
    reservoir_new_test,
    reservoir_new_custom_size_test,
    reservoir_offer_test,
    reservoir_sampling_test,
    %% Trace context tests
    exemplar_trace_context_test,
    exemplar_no_trace_context_test,
    %% Collect and reset tests
    reservoir_collect_test,
    reservoir_collect_reset_test,
    %% ETS-based API tests
    reservoir_ref_test,
    reservoir_ref_concurrent_test,
    exemplar_reservoir_survives_transient_creator_test
  ].

init_per_suite(Config) ->
  _ = application:ensure_all_started(crypto),
  ok = application:start(instrument),
  Config.

end_per_suite(_Config) ->
  ok = application:stop(instrument),
  ok.

init_per_testcase(_TestCase, Config) ->
  %% Clear context between tests
  erlang:erase('$instrument_context'),
  Config.

end_per_testcase(_TestCase, _Config) ->
  erlang:erase('$instrument_context'),
  ok.

%% ============================================================================
%% Reservoir Basic Tests
%% ============================================================================

%% Test creating a reservoir with default size
reservoir_new_test(_Config) ->
  Reservoir = instrument_exemplar:new_reservoir(),
  %% Default size is 4
  Exemplars = instrument_exemplar:collect(Reservoir),
  ?assertEqual([], Exemplars),
  ok.

%% Test creating a reservoir with custom size
reservoir_new_custom_size_test(_Config) ->
  Reservoir = instrument_exemplar:new_reservoir(10),
  %% Should be empty initially
  Exemplars = instrument_exemplar:collect(Reservoir),
  ?assertEqual([], Exemplars),
  ok.

%% Test offering values less than reservoir size
reservoir_offer_test(_Config) ->
  Reservoir0 = instrument_exemplar:new_reservoir(5),

  %% Offer 3 values (less than size)
  Reservoir1 = instrument_exemplar:offer(Reservoir0, 1.0, #{}, {undefined, undefined}),
  Reservoir2 = instrument_exemplar:offer(Reservoir1, 2.0, #{}, {undefined, undefined}),
  Reservoir3 = instrument_exemplar:offer(Reservoir2, 3.0, #{}, {undefined, undefined}),

  Exemplars = instrument_exemplar:collect(Reservoir3),
  ?assertEqual(3, length(Exemplars)),

  %% Verify values are stored
  Values = [E#exemplar.value || E <- Exemplars],
  ?assert(lists:member(1.0, Values)),
  ?assert(lists:member(2.0, Values)),
  ?assert(lists:member(3.0, Values)),
  ok.

%% Test reservoir sampling when more values offered than size
reservoir_sampling_test(_Config) ->
  Reservoir0 = instrument_exemplar:new_reservoir(4),

  %% Offer more values than reservoir size
  Reservoir = lists:foldl(fun(I, R) ->
    instrument_exemplar:offer(R, float(I), #{}, {undefined, undefined})
  end, Reservoir0, lists:seq(1, 100)),

  Exemplars = instrument_exemplar:collect(Reservoir),

  %% Should have exactly 4 exemplars (reservoir size)
  ?assertEqual(4, length(Exemplars)),

  %% All exemplars should have valid values
  lists:foreach(fun(E) ->
    ?assert(is_number(E#exemplar.value)),
    ?assert(E#exemplar.value >= 1.0),
    ?assert(E#exemplar.value =< 100.0)
  end, Exemplars),
  ok.

%% ============================================================================
%% Trace Context Tests
%% ============================================================================

%% Test that exemplar captures trace context within a span
exemplar_trace_context_test(_Config) ->
  Reservoir0 = instrument_exemplar:new_reservoir(4),

  instrument_tracer:with_span(<<"test_span">>, fun() ->
    %% Get current trace context
    SpanCtx = instrument_tracer:span_ctx(),
    ExpectedTraceId = SpanCtx#span_ctx.trace_id,
    ExpectedSpanId = SpanCtx#span_ctx.span_id,

    %% Offer a value (will capture trace context automatically)
    Reservoir1 = instrument_exemplar:offer(Reservoir0, 42.0, #{}),
    Exemplars = instrument_exemplar:collect(Reservoir1),

    ?assertEqual(1, length(Exemplars)),
    [Exemplar] = Exemplars,

    %% Verify trace context was captured
    ?assertEqual(ExpectedTraceId, Exemplar#exemplar.trace_id),
    ?assertEqual(ExpectedSpanId, Exemplar#exemplar.span_id),
    ?assertEqual(42.0, Exemplar#exemplar.value)
  end),
  ok.

%% Test exemplar without trace context (no active span)
exemplar_no_trace_context_test(_Config) ->
  Reservoir0 = instrument_exemplar:new_reservoir(4),

  %% Offer value outside of any span
  Reservoir1 = instrument_exemplar:offer(Reservoir0, 99.0, #{}),
  Exemplars = instrument_exemplar:collect(Reservoir1),

  ?assertEqual(1, length(Exemplars)),
  [Exemplar] = Exemplars,

  %% Trace context should be undefined
  ?assertEqual(undefined, Exemplar#exemplar.trace_id),
  ?assertEqual(undefined, Exemplar#exemplar.span_id),
  ?assertEqual(99.0, Exemplar#exemplar.value),
  ok.

%% ============================================================================
%% Collect and Reset Tests
%% ============================================================================

%% Test collecting exemplars preserves order
reservoir_collect_test(_Config) ->
  Reservoir0 = instrument_exemplar:new_reservoir(10),

  %% Offer values in order
  Reservoir = lists:foldl(fun(I, R) ->
    instrument_exemplar:offer(R, float(I), #{}, {undefined, undefined})
  end, Reservoir0, lists:seq(1, 5)),

  Exemplars = instrument_exemplar:collect(Reservoir),
  ?assertEqual(5, length(Exemplars)),

  %% First offered should be first in collected (FIFO order)
  [First | _] = Exemplars,
  ?assertEqual(1.0, First#exemplar.value),
  ok.

%% Test that reset clears the reservoir
reservoir_collect_reset_test(_Config) ->
  Reservoir0 = instrument_exemplar:new_reservoir(4),

  %% Offer values
  Reservoir1 = instrument_exemplar:offer(Reservoir0, 1.0, #{}, {undefined, undefined}),
  Reservoir2 = instrument_exemplar:offer(Reservoir1, 2.0, #{}, {undefined, undefined}),

  %% Verify values are stored
  Exemplars1 = instrument_exemplar:collect(Reservoir2),
  ?assertEqual(2, length(Exemplars1)),

  %% Reset the reservoir
  Reservoir3 = instrument_exemplar:reset(Reservoir2),

  %% Should be empty after reset
  Exemplars2 = instrument_exemplar:collect(Reservoir3),
  ?assertEqual([], Exemplars2),
  ok.

%% ============================================================================
%% ETS-based API Tests
%% ============================================================================

%% Test ETS-based reservoir reference API
reservoir_ref_test(_Config) ->
  %% Create a new reservoir reference
  Ref = instrument_exemplar:new_reservoir_ref(4),
  ?assert(is_reference(Ref)),

  %% Offer values
  ok = instrument_exemplar:offer_ref(Ref, 10.0, #{}),
  ok = instrument_exemplar:offer_ref(Ref, 20.0, #{}),
  ok = instrument_exemplar:offer_ref(Ref, 30.0, #{}),

  %% Collect
  Exemplars = instrument_exemplar:collect_ref(Ref),
  ?assertEqual(3, length(Exemplars)),

  Values = [E#exemplar.value || E <- Exemplars],
  ?assert(lists:member(10.0, Values)),
  ?assert(lists:member(20.0, Values)),
  ?assert(lists:member(30.0, Values)),

  %% Reset
  ok = instrument_exemplar:reset_ref(Ref),
  EmptyExemplars = instrument_exemplar:collect_ref(Ref),
  ?assertEqual([], EmptyExemplars),
  ok.

%% Test concurrent access to ETS-based reservoir
reservoir_ref_concurrent_test(_Config) ->
  Ref = instrument_exemplar:new_reservoir_ref(4),
  Parent = self(),
  NumProcs = 20,
  OffersPerProc = 10,

  %% Spawn processes that offer values concurrently
  Pids = [spawn_link(fun() ->
    lists:foreach(fun(I) ->
      Value = float(ProcId * 100 + I),
      ok = instrument_exemplar:offer_ref(Ref, Value, #{})
    end, lists:seq(1, OffersPerProc)),
    Parent ! {self(), done}
  end) || ProcId <- lists:seq(1, NumProcs)],

  %% Wait for all processes
  lists:foreach(fun(Pid) ->
    receive {Pid, done} -> ok after 5000 -> ct:fail(timeout) end
  end, Pids),

  %% Collect exemplars
  Exemplars = instrument_exemplar:collect_ref(Ref),

  %% Should have at most 4 exemplars (reservoir size)
  ?assertEqual(4, length(Exemplars)),

  %% All exemplars should have valid values
  lists:foreach(fun(E) ->
    ?assert(is_number(E#exemplar.value)),
    ?assert(E#exemplar.value >= 1.0)
  end, Exemplars),
  ok.

%% Regression: the exemplar reservoir table must be created at startup and owned
%% by the supervised registry, so a histogram recorded from a short-lived process
%% does not orphan it. Pre-fix the table is created lazily by the first recorder
%% and deleted when that process exits, badarg-ing every later offer_ref/3.
exemplar_reservoir_survives_transient_creator_test(_Config) ->
  Tid = ets:whereis(instrument_exemplar_reservoirs),
  ?assertNotEqual(undefined, Tid),
  ?assertEqual(whereis(instrument_registry), ets:info(Tid, owner)),

  Parent = self(),
  {Worker, MRef} = spawn_monitor(fun() ->
    Ref = instrument_exemplar:new_reservoir_ref(4),
    ok = instrument_exemplar:offer_ref(Ref, 1.0, #{}),
    Parent ! {reservoir_ref, Ref}
  end),
  Ref = receive {reservoir_ref, R} -> R after 5000 -> ct:fail(no_ref_from_worker) end,
  receive {'DOWN', MRef, process, Worker, _} -> ok after 5000 -> ct:fail(worker_did_not_exit) end,

  ?assertNotEqual(undefined, ets:whereis(instrument_exemplar_reservoirs)),
  ?assertEqual(ok, instrument_exemplar:offer_ref(Ref, 2.0, #{})),
  %% reservoir size 4 >> 2 offers, so both values are retained (no sampling)
  Values = [E#exemplar.value || E <- instrument_exemplar:collect_ref(Ref)],
  ?assertEqual(2, length(Values)),
  ?assert(lists:member(1.0, Values)),
  ?assert(lists:member(2.0, Values)),

  %% tidy the row we created so it does not linger in the shared table
  ok = instrument_exemplar:delete_reservoir(Ref).
