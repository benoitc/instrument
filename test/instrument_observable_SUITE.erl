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
  %% Callbacks registered for several instruments
  batch_callback_feeds_several_instruments/1,
  batch_callback_attributes_use_real_name/1,
  batch_callback_unregister_stops_calls/1,
  batch_callback_ignores_unregistered_target/1,
  batch_callback_error_isolated/1,
  batch_callback_skips_removed_instrument/1,
  batch_callback_rejects_bad_instruments/1,
  observable_with_opts_has_no_own_callback/1
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
    %% Callbacks registered for several instruments
    batch_callback_feeds_several_instruments,
    batch_callback_attributes_use_real_name,
    batch_callback_unregister_stops_calls,
    batch_callback_ignores_unregistered_target,
    batch_callback_error_isolated,
    batch_callback_skips_removed_instrument,
    batch_callback_rejects_bad_instruments,
    observable_with_opts_has_no_own_callback
  ].

init_per_suite(Config) ->
  _ = application:ensure_all_started(crypto),
  {ok, _} = application:ensure_all_started(instrument),
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

  %% format/0 runs the observable callbacks itself, so the single collect that
  %% renders this scrape comes from format/0 — the callback fires once (count
  %% -> 1). (An extra explicit collect would advance this incrementing callback
  %% and is no longer needed.)
  Output = instrument_prometheus:format(),

  %% Render must include the counter type tag and the `_total` suffix.
  ?assertNotEqual(nomatch,
                  binary:match(Output, <<"# TYPE obs_counter_unlabeled_total counter">>)),
  ?assertNotEqual(nomatch,
                  binary:match(Output, <<"obs_counter_unlabeled_total 1.0">>)),

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

  %% Attributed observations render under the real instrument name as one
  %% family; the attribute is a label, never part of the name.
  ?assertNotEqual(nomatch,
                  binary:match(Output, <<"# TYPE obs_counter_labeled_total counter">>)),
  ?assertNotEqual(nomatch,
                  binary:match(Output,
                               <<"obs_counter_labeled_total{region=\"us-east\"} 7.0">>)),

  %% No derived `_region` family exists.
  ?assertEqual(nomatch,
               binary:match(Output, <<"obs_counter_labeled_region">>)),

  %% Must NOT be misrendered as gauge.
  ?assertEqual(nomatch,
               binary:match(Output, <<"# TYPE obs_counter_labeled_total gauge">>)),
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

  %% Both label-key schemas live under ONE family with the real name; the
  %% label columns are the union {a, b}, and the {a}-only row renders b="".
  ?assertNotEqual(nomatch,
                  binary:match(Output, <<"# TYPE obs_counter_multi_schema_total counter">>)),
  ?assertNotEqual(nomatch,
                  binary:match(Output,
                               <<"obs_counter_multi_schema_total{a=\"x\",b=\"\"} 5.0">>)),
  ?assertNotEqual(nomatch,
                  binary:match(Output,
                               <<"obs_counter_multi_schema_total{a=\"x\",b=\"y\"} 7.0">>)),

  %% No derived per-schema families exist.
  ?assertEqual(nomatch,
               binary:match(Output, <<"obs_counter_multi_schema_a_total">>)),
  ?assertEqual(nomatch,
               binary:match(Output, <<"obs_counter_multi_schema_a_b_total">>)),
  ok.

%% ============================================================================
%% Callbacks registered for several instruments
%% ============================================================================

%% One fetch per collection feeds a counter, a gauge and an up/down counter.
batch_callback_feeds_several_instruments(_Config) ->
  Meter = instrument_meter:get_meter(<<"batch_feed_test">>),
  C = instrument_meter:create_observable_counter(Meter, <<"batch_feed_counter">>, #{}),
  G = instrument_meter:create_observable_gauge(Meter, <<"batch_feed_gauge">>, #{}),
  U = instrument_meter:create_observable_up_down_counter(Meter, <<"batch_feed_updown">>, #{}),
  Fetches = atomics:new(1, []),
  {ok, Ref} = instrument_meter:register_callback([C, G, U], fun(Observe) ->
    atomics:add(Fetches, 1, 1),
    #{done := D, depth := Q, delta := X} = #{done => 10, depth => 3, delta => -2},
    ok = Observe(C, D, #{}),
    ok = Observe(G, Q, #{}),
    ok = Observe(<<"batch_feed_updown">>, X, #{})
  end),
  ok = instrument_meter:collect_observables(),
  ?assertEqual(1, atomics:get(Fetches, 1)),
  ok = instrument_meter:collect_observables(),
  ?assertEqual(2, atomics:get(Fetches, 1)),
  Output = instrument_prometheus:format(),
  ?assertNotEqual(nomatch, binary:match(Output, <<"batch_feed_counter_total 10.0">>)),
  ?assertNotEqual(nomatch, binary:match(Output, <<"batch_feed_gauge 3.0">>)),
  ?assertNotEqual(nomatch, binary:match(Output, <<"batch_feed_updown -2.0">>)),
  ok = instrument_meter:unregister_callback(Ref).

%% Attributes become labels under the instrument's own name.
batch_callback_attributes_use_real_name(_Config) ->
  Meter = instrument_meter:get_meter(<<"batch_attr_test">>),
  G = instrument_meter:create_observable_gauge(Meter, <<"batch_attr_queue">>, #{}),
  {ok, Ref} = instrument_meter:register_callback([G], fun(Observe) ->
    Observe(G, 4, #{queue => <<"orders">>}),
    Observe(G, 9, #{queue => <<"billing">>})
  end),
  Output = instrument_prometheus:format(),
  ?assertNotEqual(nomatch, binary:match(Output, <<"batch_attr_queue{queue=\"orders\"} 4.0">>)),
  ?assertNotEqual(nomatch, binary:match(Output, <<"batch_attr_queue{queue=\"billing\"} 9.0">>)),
  ?assertEqual(nomatch, binary:match(Output, <<"batch_attr_queue_queue">>)),
  ok = instrument_meter:unregister_callback(Ref).

batch_callback_unregister_stops_calls(_Config) ->
  Meter = instrument_meter:get_meter(<<"batch_unreg_test">>),
  G = instrument_meter:create_observable_gauge(Meter, <<"batch_unreg_gauge">>, #{}),
  Calls = atomics:new(1, []),
  {ok, Ref} = instrument_meter:register_callback([G], fun(Observe) ->
    atomics:add(Calls, 1, 1),
    Observe(G, 1, #{})
  end),
  ok = instrument_meter:collect_observables(),
  ?assertEqual(1, atomics:get(Calls, 1)),
  ok = instrument_meter:unregister_callback(Ref),
  ok = instrument_meter:collect_observables(),
  ?assertEqual(1, atomics:get(Calls, 1)),
  %% Unregistering twice is harmless.
  ok = instrument_meter:unregister_callback(Ref).

%% A callback can only observe the instruments it was registered with.
batch_callback_ignores_unregistered_target(_Config) ->
  Meter = instrument_meter:get_meter(<<"batch_target_test">>),
  Mine = instrument_meter:create_observable_gauge(Meter, <<"batch_target_mine">>, #{}),
  Other = instrument_meter:create_observable_gauge(Meter, <<"batch_target_other">>, #{}),
  Self = self(),
  {ok, Ref} = instrument_meter:register_callback([Mine], fun(Observe) ->
    Self ! {results, Observe(Mine, 1, #{}), Observe(Other, 2, #{}),
            Observe(<<"batch_target_missing">>, 3, #{}), Observe(Mine, not_a_number, #{})}
  end),
  ok = instrument_meter:collect_observables(),
  receive
    {results, R1, R2, R3, R4} ->
      ?assertEqual(ok, R1),
      ?assertEqual({error, unknown_instrument}, R2),
      ?assertEqual({error, unknown_instrument}, R3),
      ?assertEqual({error, invalid_observation}, R4)
  after 1000 -> ct:fail(callback_not_invoked)
  end,
  Output = instrument_prometheus:format(),
  ?assertNotEqual(nomatch, binary:match(Output, <<"batch_target_mine 1.0">>)),
  ?assertEqual(nomatch, binary:match(Output, <<"batch_target_other">>)),
  ok = instrument_meter:unregister_callback(Ref).

%% A crashing callback keeps what it observed before the crash and does not
%% stop other callbacks.
batch_callback_error_isolated(_Config) ->
  Meter = instrument_meter:get_meter(<<"batch_error_test">>),
  A = instrument_meter:create_observable_gauge(Meter, <<"batch_error_a">>, #{}),
  B = instrument_meter:create_observable_gauge(Meter, <<"batch_error_b">>, #{}),
  {ok, R1} = instrument_meter:register_callback([A], fun(Observe) ->
    ok = Observe(A, 5, #{}),
    error(boom)
  end),
  {ok, R2} = instrument_meter:register_callback([B], fun(Observe) ->
    Observe(B, 6, #{})
  end),
  Output = instrument_prometheus:format(),
  ?assertNotEqual(nomatch, binary:match(Output, <<"batch_error_a 5.0">>)),
  ?assertNotEqual(nomatch, binary:match(Output, <<"batch_error_b 6.0">>)),
  ok = instrument_meter:unregister_callback(R1),
  ok = instrument_meter:unregister_callback(R2).

%% An instrument removed after registration is skipped; the others still work.
batch_callback_skips_removed_instrument(_Config) ->
  Meter = instrument_meter:get_meter(<<"batch_removed_test">>),
  Keep = instrument_meter:create_observable_gauge(Meter, <<"batch_removed_keep">>, #{}),
  Gone = instrument_meter:create_observable_gauge(Meter, <<"batch_removed_gone">>, #{}),
  Self = self(),
  {ok, Ref} = instrument_meter:register_callback([Keep, Gone], fun(Observe) ->
    Self ! {gone, Observe(Gone, 2, #{})},
    Observe(Keep, 1, #{})
  end),
  ok = instrument_meter:unregister_instrument(<<"batch_removed_gone">>),
  Output = instrument_prometheus:format(),
  receive
    {gone, R} -> ?assertEqual({error, unknown_instrument}, R)
  after 1000 -> ct:fail(callback_not_invoked)
  end,
  ?assertNotEqual(nomatch, binary:match(Output, <<"batch_removed_keep 1.0">>)),
  ?assertEqual(nomatch, binary:match(Output, <<"batch_removed_gone">>)),
  ok = instrument_meter:unregister_callback(Ref).

batch_callback_rejects_bad_instruments(_Config) ->
  Meter = instrument_meter:get_meter(<<"batch_reject_test">>),
  Sync = instrument_meter:create_counter(Meter, <<"batch_reject_sync">>),
  G = instrument_meter:create_observable_gauge(Meter, <<"batch_reject_gauge">>, #{}),
  Cb = fun(_) -> ok end,
  ?assertEqual({error, no_instruments}, instrument_meter:register_callback([], Cb)),
  ?assertEqual({error, {not_observable, <<"batch_reject_sync">>}},
               instrument_meter:register_callback([G, Sync], Cb)),
  ?assertEqual({error, {not_an_instrument, <<"batch_reject_gauge">>}},
               instrument_meter:register_callback([<<"batch_reject_gauge">>], Cb)),
  ?assertEqual({error, badarg}, instrument_meter:register_callback([G], fun() -> ok end)),
  ok.

%% Created with an options map: no callback of its own, description kept,
%% nothing exported until a registered callback observes it.
observable_with_opts_has_no_own_callback(_Config) ->
  Meter = instrument_meter:get_meter(<<"batch_opts_test">>),
  G = instrument_meter:create_observable_gauge(Meter, <<"batch_opts_gauge">>,
        #{description => <<"Queue depth">>, unit => <<"1">>}),
  ?assertEqual(observable_gauge, G#otel_instrument.kind),
  ?assertEqual(<<"Queue depth">>, G#otel_instrument.description),
  ?assertEqual(<<"1">>, G#otel_instrument.unit),
  ok = instrument_meter:collect_observables(),
  ?assertEqual(nomatch, binary:match(instrument_prometheus:format(), <<"batch_opts_gauge ">>)),
  {ok, Ref} = instrument_meter:register_callback([G], fun(Observe) -> Observe(G, 8, #{}) end),
  ?assertNotEqual(nomatch,
                  binary:match(instrument_prometheus:format(), <<"batch_opts_gauge 8.0">>)),
  ok = instrument_meter:unregister_callback(Ref).
