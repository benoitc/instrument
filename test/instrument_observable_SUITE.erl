%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_observable_SUITE).
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
  observable_gauge_test/1,
  observable_counter_test/1,
  observable_up_down_counter_test/1,
  collect_observables_test/1,
  observable_callback_error_test/1,
  multiple_observables_test/1,
  %% Observer callback tests (OTel spec compliance)
  observable_observer_callback_test/1,
  observable_legacy_callback_test/1,
  observable_multi_attribute_test/1,
  observable_counter_unlabeled_renders_as_counter/1,
  observable_counter_renders_as_counter/1,
  observable_counter_with_multiple_label_schemas/1,
  %% Shared collection-context tests
  observable_context_callback_test/1,
  observable_context_shared_source_test/1
]).

all() ->
  [
    observable_gauge_test,
    observable_counter_test,
    observable_up_down_counter_test,
    collect_observables_test,
    observable_callback_error_test,
    multiple_observables_test,
    %% Observer callback tests (OTel spec compliance)
    observable_observer_callback_test,
    observable_legacy_callback_test,
    observable_multi_attribute_test,
    observable_counter_unlabeled_renders_as_counter,
    observable_counter_renders_as_counter,
    observable_counter_with_multiple_label_schemas,
    %% Shared collection-context tests
    observable_context_callback_test,
    observable_context_shared_source_test
  ].

init_per_suite(Config) ->
  _ = application:ensure_all_started(crypto),
  ok = application:start(instrument),
  Config.

end_per_suite(_Config) ->
  ok = application:stop(instrument),
  ok.

init_per_testcase(_TestCase, Config) ->
  Config.

end_per_testcase(_TestCase, _Config) ->
  ok.

%% ============================================================================
%% Test Cases
%% ============================================================================

observable_gauge_test(_Config) ->
  %% Create a process to hold a dynamic value
  ValueRef = atomics:new(1, [{signed, true}]),
  atomics:put(ValueRef, 1, 42),

  Meter = instrument_meter:get_meter(<<"test_observable">>),
  Callback = fun() -> atomics:get(ValueRef, 1) end,

  Gauge = instrument_meter:create_observable_gauge(Meter, <<"obs_gauge_test">>, Callback),

  ?assertEqual(observable_gauge, Gauge#otel_instrument.kind),
  ?assertEqual(<<"obs_gauge_test">>, Gauge#otel_instrument.name),

  %% Update the value
  atomics:put(ValueRef, 1, 100),

  %% Collect observables to trigger callback
  ok = instrument_meter:collect_observables(),

  ok.

observable_counter_test(_Config) ->
  %% Counter that tracks cumulative count
  CountRef = atomics:new(1, [{signed, false}]),
  atomics:put(CountRef, 1, 0),

  Meter = instrument_meter:get_meter(<<"test_observable">>),
  Callback = fun() ->
    atomics:add(CountRef, 1, 1),
    atomics:get(CountRef, 1)
  end,

  Counter = instrument_meter:create_observable_counter(Meter, <<"obs_counter_test">>, Callback),

  ?assertEqual(observable_counter, Counter#otel_instrument.kind),

  %% First collection
  ok = instrument_meter:collect_observables(),
  ?assertEqual(1, atomics:get(CountRef, 1)),

  %% Second collection
  ok = instrument_meter:collect_observables(),
  ?assertEqual(2, atomics:get(CountRef, 1)),

  ok.

observable_up_down_counter_test(_Config) ->
  %% UpDownCounter that can go up and down
  ValueRef = atomics:new(1, [{signed, true}]),
  atomics:put(ValueRef, 1, 50),

  Meter = instrument_meter:get_meter(<<"test_observable">>),
  Callback = fun() -> atomics:get(ValueRef, 1) end,

  UpDownCounter = instrument_meter:create_observable_up_down_counter(
    Meter, <<"obs_updown_test">>, Callback
  ),

  ?assertEqual(observable_up_down_counter, UpDownCounter#otel_instrument.kind),

  %% Initial collection
  ok = instrument_meter:collect_observables(),

  %% Value goes down
  atomics:put(ValueRef, 1, 30),
  ok = instrument_meter:collect_observables(),

  %% Value goes up
  atomics:put(ValueRef, 1, 75),
  ok = instrument_meter:collect_observables(),

  ok.

collect_observables_test(_Config) ->
  %% Test that collect_observables invokes callbacks and updates values
  ValueRef = atomics:new(1, [{signed, true}]),
  atomics:put(ValueRef, 1, 999),

  Meter = instrument_meter:get_meter(<<"test_collect">>),
  _Gauge = instrument_meter:create_observable_gauge(
    Meter,
    <<"collect_test_gauge">>,
    fun() -> atomics:get(ValueRef, 1) end
  ),

  %% Collect observables
  ok = instrument_meter:collect_observables(),

  %% Verify the instrument is registered
  Inst = instrument_meter:get_instrument(<<"collect_test_gauge">>),
  ?assertNotEqual(undefined, Inst),
  ok.

observable_callback_error_test(_Config) ->
  %% Test that callback errors are handled gracefully
  Meter = instrument_meter:get_meter(<<"test_error">>),

  %% Callback that throws an error
  _ErrorGauge = instrument_meter:create_observable_gauge(
    Meter,
    <<"error_gauge">>,
    fun() -> error(intentional_error) end
  ),

  %% This should not crash
  ok = instrument_meter:collect_observables(),
  ok.

multiple_observables_test(_Config) ->
  %% Test multiple observable instruments
  Val1 = atomics:new(1, [{signed, true}]),
  Val2 = atomics:new(1, [{signed, true}]),
  Val3 = atomics:new(1, [{signed, true}]),

  atomics:put(Val1, 1, 10),
  atomics:put(Val2, 1, 20),
  atomics:put(Val3, 1, 30),

  Meter = instrument_meter:get_meter(<<"test_multi">>),

  _G1 = instrument_meter:create_observable_gauge(
    Meter, <<"multi_gauge1">>, fun() -> atomics:get(Val1, 1) end
  ),
  _G2 = instrument_meter:create_observable_gauge(
    Meter, <<"multi_gauge2">>, fun() -> atomics:get(Val2, 1) end
  ),
  _G3 = instrument_meter:create_observable_gauge(
    Meter, <<"multi_gauge3">>, fun() -> atomics:get(Val3, 1) end
  ),

  %% All callbacks should be invoked
  ok = instrument_meter:collect_observables(),

  %% Update values
  atomics:put(Val1, 1, 100),
  atomics:put(Val2, 1, 200),
  atomics:put(Val3, 1, 300),

  %% Collect again
  ok = instrument_meter:collect_observables(),

  ok.

%% ============================================================================
%% Observer Callback Tests (OTel Spec Compliance)
%% ============================================================================

%% Test 1-arity observer callback pattern
observable_observer_callback_test(_Config) ->
  Meter = instrument_meter:get_meter(<<"observer_test">>),

  %% Create observable gauge with 1-arity callback (observer pattern)
  %% Callback receives an Observe function it calls for each value
  _Gauge = instrument_meter:create_observable_gauge(
    Meter,
    <<"observer_gauge">>,
    fun(Observe) ->
      %% Report multiple values with attributes
      Observe(42.0, #{host => <<"server1">>}),
      Observe(55.0, #{host => <<"server2">>}),
      Observe(30.0, #{host => <<"server3">>}),
      ok
    end
  ),

  %% Collect observables - this invokes the callback
  ok = instrument_meter:collect_observables(),

  %% Collect metrics and verify observations were recorded
  Metrics = instrument_metrics_exporter:collect(),

  %% Find our gauge metrics (may have vec suffix due to attributes)
  GaugeMetrics = [M || #{name := N} = M <- Metrics,
                       binary:match(N, <<"observer_gauge">>) =/= nomatch],

  %% Should have created metrics for the observations
  ?assert(length(GaugeMetrics) >= 1),
  ok.

%% Test that 0-arity callback (legacy) still works
observable_legacy_callback_test(_Config) ->
  ValueRef = atomics:new(1, [{signed, true}]),
  atomics:put(ValueRef, 1, 123),

  Meter = instrument_meter:get_meter(<<"legacy_test">>),

  %% Create observable with 0-arity callback (legacy pattern)
  _Gauge = instrument_meter:create_observable_gauge(
    Meter,
    <<"legacy_callback_gauge">>,
    fun() -> atomics:get(ValueRef, 1) end
  ),

  %% Collect observables
  ok = instrument_meter:collect_observables(),

  %% Collect metrics
  Metrics = instrument_metrics_exporter:collect(),

  %% Find our gauge
  GaugeMetrics = [M || #{name := N} = M <- Metrics,
                       binary:match(N, <<"legacy_callback_gauge">>) =/= nomatch],

  ?assert(length(GaugeMetrics) >= 1),

  %% Update value and collect again
  atomics:put(ValueRef, 1, 456),
  ok = instrument_meter:collect_observables(),

  ok.

%% Test observing multiple hosts/entities with attributes
observable_multi_attribute_test(_Config) ->
  Meter = instrument_meter:get_meter(<<"multi_attr_test">>),

  %% Simulate monitoring multiple hosts
  HostData = #{
    <<"host1.example.com">> => 75.5,
    <<"host2.example.com">> => 82.3,
    <<"host3.example.com">> => 45.0,
    <<"host4.example.com">> => 91.2
  },

  %% Create observable gauge with observer callback
  _CpuGauge = instrument_meter:create_observable_gauge(
    Meter,
    <<"cpu_usage">>,
    fun(Observe) ->
      maps:foreach(fun(Host, Cpu) ->
        Observe(Cpu, #{hostname => Host, region => <<"us-east">>})
      end, HostData),
      ok
    end
  ),

  %% Collect observables
  ok = instrument_meter:collect_observables(),

  %% Collect metrics
  Metrics = instrument_metrics_exporter:collect(),

  %% Find CPU usage metrics
  CpuMetrics = [M || #{name := N} = M <- Metrics,
                     binary:match(N, <<"cpu_usage">>) =/= nomatch],

  %% Should have created metrics for multi-attribute observations
  ?assert(length(CpuMetrics) >= 1),

  %% Verify we have data points (either in vec or base metric)
  TotalDataPoints = lists:sum([length(maps:get(data_points, M, [])) || M <- CpuMetrics]),

  %% Should have recorded observations (at least one data point)
  ?assert(TotalDataPoints >= 1),
  ok.

observable_counter_unlabeled_renders_as_counter(_Config) ->
  CountRef = atomics:new(1, [{signed, false}]),
  atomics:put(CountRef, 1, 0),

  Meter = instrument_meter:get_meter(<<"obs_counter_unlabeled_test">>),
  Callback = fun() ->
    atomics:add(CountRef, 1, 1),
    atomics:get(CountRef, 1)
  end,
  _Counter = instrument_meter:create_observable_counter(
              Meter, <<"obs_counter_unlabeled">>, Callback),

  ok = instrument_meter:collect_observables(),

  Output = instrument_prometheus:format(),

  %% Render must include the counter type tag and the `_total` suffix.
  ?assertNotEqual(nomatch,
                  binary:match(Output, <<"# TYPE obs_counter_unlabeled_total counter">>)),
  ?assertNotEqual(nomatch,
                  binary:match(Output, <<"obs_counter_unlabeled_total 1">>)),

  %% Must NOT be misrendered as gauge.
  ?assertEqual(nomatch,
               binary:match(Output, <<"# TYPE obs_counter_unlabeled gauge">>)),
  ok.

observable_counter_renders_as_counter(_Config) ->
  Meter = instrument_meter:get_meter(<<"obs_counter_labeled_test">>),

  %% 1-arity callback emits one labeled observation per scrape.
  Callback = fun(Observer) ->
    Observer(7, #{region => <<"us-east">>})
  end,
  _ = instrument_meter:create_observable_counter(
        Meter, <<"obs_counter_labeled">>, Callback),

  ok = instrument_meter:collect_observables(),
  Output = instrument_prometheus:format(),

  %% The labeled vec name carries the sorted-attrs suffix (`_region`).
  %% format_counter adds `_total` on top of that.
  ?assertNotEqual(nomatch,
                  binary:match(Output, <<"# TYPE obs_counter_labeled_region_total counter">>)),
  ?assertNotEqual(nomatch,
                  binary:match(Output,
                               <<"obs_counter_labeled_region_total{region=\"us-east\"} 7.0">>)),

  %% Must NOT be misrendered as gauge.
  ?assertEqual(nomatch,
               binary:match(Output, <<"# TYPE obs_counter_labeled_region gauge">>)),
  ok.

observable_counter_with_multiple_label_schemas(_Config) ->
  Meter = instrument_meter:get_meter(<<"obs_counter_multi_schema_test">>),

  %% One observable counter, two distinct attribute-key schemas
  %% emitted from a single scrape.
  Callback = fun(Observer) ->
    Observer(5, #{a => <<"x">>}),
    Observer(7, #{a => <<"x">>, b => <<"y">>})
  end,
  _ = instrument_meter:create_observable_counter(
        Meter, <<"obs_counter_multi_schema">>, Callback),

  ok = instrument_meter:collect_observables(),
  Output = instrument_prometheus:format(),

  %% Each label-key schema produces its own vec (suffix derived from
  %% sorted attribute keys).
  ?assertNotEqual(nomatch,
                  binary:match(Output, <<"# TYPE obs_counter_multi_schema_a_total counter">>)),
  ?assertNotEqual(nomatch,
                  binary:match(Output, <<"obs_counter_multi_schema_a_total{a=\"x\"} 5.0">>)),

  ?assertNotEqual(nomatch,
                  binary:match(Output, <<"# TYPE obs_counter_multi_schema_a_b_total counter">>)),
  ?assertNotEqual(nomatch,
                  binary:match(Output,
                               <<"obs_counter_multi_schema_a_b_total{a=\"x\",b=\"y\"} 7.0">>)),
  ok.

%% ============================================================================
%% Shared Collection-Context Tests
%% ============================================================================

%% An arity-2 callback is accepted at registration, is invoked with an
%% observer and a map context, and its observations are recorded like any
%% other observable.
observable_context_callback_test(_Config) ->
  Parent = self(),
  Meter = instrument_meter:get_meter(<<"ctx_cb_test">>),
  Gauge = instrument_meter:create_observable_gauge(
    Meter,
    <<"ctx_cb_gauge">>,
    fun(Observe, Ctx) ->
      Parent ! {ctx_seen, Ctx},
      Observe(42.0, #{host => <<"a">>}),
      Ctx
    end
  ),
  ?assertEqual(observable_gauge, Gauge#otel_instrument.kind),
  ?assertEqual(<<"ctx_cb_gauge">>, Gauge#otel_instrument.name),
  ok = instrument_meter:collect_observables(),
  receive
    {ctx_seen, Ctx} -> ?assert(is_map(Ctx))
  after 1000 ->
    ct:fail(arity2_callback_not_invoked)
  end,
  %% Note: collect/0 triggers a second collection cycle internally;
  %% a second {ctx_seen, _} message may sit in the mailbox. Harmless.
  Metrics = instrument_metrics_exporter:collect(),
  GaugeMetrics = [M || #{name := N} = M <- Metrics,
                       binary:match(N, <<"ctx_cb_gauge">>) =/= nomatch],
  ?assert(length(GaugeMetrics) >= 1),
  ok.

%% Two callbacks share one expensive source through the context: the source
%% runs exactly once per cycle, and again on the next cycle (fresh map).
observable_context_shared_source_test(_Config) ->
  SourceCalls = atomics:new(1, [{signed, false}]),
  GetOrCompute = fun(Ctx) ->
    case Ctx of
      #{ctx_shared_stats := S} ->
        {S, Ctx};
      _ ->
        atomics:add(SourceCalls, 1, 1),
        S = #{queue_depth => 5, connections => 3},
        {S, Ctx#{ctx_shared_stats => S}}
    end
  end,
  Meter = instrument_meter:get_meter(<<"ctx_shared_test">>),
  _G1 = instrument_meter:create_observable_gauge(
    Meter,
    <<"ctx_shared_queue_depth">>,
    fun(Observe, Ctx) ->
      {Stats, Ctx1} = GetOrCompute(Ctx),
      Observe(maps:get(queue_depth, Stats), #{}),
      Ctx1
    end
  ),
  _G2 = instrument_meter:create_observable_gauge(
    Meter,
    <<"ctx_shared_connections">>,
    fun(Observe, Ctx) ->
      {Stats, Ctx1} = GetOrCompute(Ctx),
      Observe(maps:get(connections, Stats), #{}),
      Ctx1
    end
  ),
  %% One cycle: whichever callback runs first computes; the other reuses.
  %% (Do NOT call instrument_metrics_exporter:collect/0 here - it runs an
  %% extra cycle and would skew the source-call count.)
  ok = instrument_meter:collect_observables(),
  ?assertEqual(1, atomics:get(SourceCalls, 1)),
  %% Next cycle seeds a fresh map: the source is computed again.
  ok = instrument_meter:collect_observables(),
  ?assertEqual(2, atomics:get(SourceCalls, 1)),
  ok.
