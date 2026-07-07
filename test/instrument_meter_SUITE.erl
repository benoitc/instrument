%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_meter_SUITE).
-author("benoitc").

-export([
  all/0,
  init_per_suite/1,
  end_per_suite/1,
  init_per_testcase/2,
  end_per_testcase/2
]).

-export([
  get_meter/1,
  create_counter/1,
  counter_add/1,
  create_up_down_counter/1,
  create_histogram/1,
  histogram_record/1,
  create_gauge/1,
  gauge_set/1,
  attributes_operations/1,
  %% New tests
  counter_with_attributes_test/1,
  gauge_with_attributes_test/1,
  histogram_with_attributes_test/1,
  attribute_cardinality_test/1,
  unregister_instrument_test/1,
  unregister_all_instruments_test/1,
  unregister_cleans_vec_metrics_test/1,
  concurrent_attribute_operations_test/1,
  description_unit_preserved_test/1,
  %% Temporality tests (OTel spec compliance)
  temporality_option_cumulative_test/1,
  temporality_option_delta_test/1,
  temporality_default_test/1,
  add_negative_to_labeled_up_down_counter/1,
  add_negative_to_unlabeled_up_down_counter/1
]).

-include("instrument_otel.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
  [
    get_meter,
    create_counter,
    counter_add,
    create_up_down_counter,
    create_histogram,
    histogram_record,
    create_gauge,
    gauge_set,
    attributes_operations,
    %% New tests
    counter_with_attributes_test,
    gauge_with_attributes_test,
    histogram_with_attributes_test,
    attribute_cardinality_test,
    unregister_instrument_test,
    unregister_all_instruments_test,
    unregister_cleans_vec_metrics_test,
    concurrent_attribute_operations_test,
    description_unit_preserved_test,
    %% Temporality tests (OTel spec compliance)
    temporality_option_cumulative_test,
    temporality_option_delta_test,
    temporality_default_test,
    add_negative_to_labeled_up_down_counter,
    add_negative_to_unlabeled_up_down_counter
  ].

init_per_suite(Config) ->
  ok = application:start(instrument),
  Config.

end_per_suite(Config) ->
  ok = application:stop(instrument),
  Config.

init_per_testcase(_, Config) ->
  _ = instrument_meter:unregister_all_instruments(),
  _ = instrument_metric:unregister_all(),
  Config.

end_per_testcase(_, _Config) ->
  ok.

%% ============================================================================
%% Meter Tests
%% ============================================================================

get_meter(_Config) ->
  Meter = instrument_meter:get_meter(<<"my_service">>),
  #meter{name = <<"my_service">>} = Meter,

  Meter2 = instrument_meter:get_meter(my_service, #{version => <<"1.0.0">>}),
  #meter{name = <<"my_service">>, version = <<"1.0.0">>} = Meter2,
  ok.

create_counter(_Config) ->
  Meter = instrument_meter:get_meter(<<"test">>),

  Counter = instrument_meter:create_counter(Meter, <<"requests_total">>, #{
    description => <<"Total requests">>,
    unit => <<"1">>
  }),

  #otel_instrument{
    name = <<"requests_total">>,
    kind = counter,
    description = <<"Total requests">>,
    unit = <<"1">>
  } = Counter,
  ok.

counter_add(_Config) ->
  Meter = instrument_meter:get_meter(<<"test">>),
  Counter = instrument_meter:create_counter(Meter, <<"counter1">>),

  ok = instrument_meter:add(Counter, 1),
  ok = instrument_meter:add(Counter, 5),
  ok = instrument_meter:add(Counter, 10, #{method => <<"GET">>}),

  %% Counter should have accumulated value
  %% Note: We can't easily check the value without accessing the underlying metric
  ok.

create_up_down_counter(_Config) ->
  Meter = instrument_meter:get_meter(<<"test">>),

  Counter = instrument_meter:create_up_down_counter(Meter, <<"active_connections">>),

  #otel_instrument{
    name = <<"active_connections">>,
    kind = up_down_counter
  } = Counter,

  ok = instrument_meter:add(Counter, 5),
  ok = instrument_meter:add(Counter, -2),
  ok.

create_histogram(_Config) ->
  Meter = instrument_meter:get_meter(<<"test">>),

  Histogram = instrument_meter:create_histogram(Meter, <<"request_duration">>, #{
    description => <<"Request duration">>,
    unit => <<"ms">>,
    boundaries => [1, 5, 10, 25, 50, 100, 250, 500, 1000]
  }),

  #otel_instrument{
    name = <<"request_duration">>,
    kind = histogram,
    unit = <<"ms">>
  } = Histogram,
  ok.

histogram_record(_Config) ->
  Meter = instrument_meter:get_meter(<<"test">>),
  Histogram = instrument_meter:create_histogram(Meter, <<"latency">>),

  ok = instrument_meter:record(Histogram, 15.5),
  ok = instrument_meter:record(Histogram, 25.0),
  ok = instrument_meter:record(Histogram, 100.0, #{endpoint => <<"/api">>}),
  ok.

create_gauge(_Config) ->
  Meter = instrument_meter:get_meter(<<"test">>),

  Gauge = instrument_meter:create_gauge(Meter, <<"temperature">>, #{
    description => <<"Current temperature">>,
    unit => <<"celsius">>
  }),

  #otel_instrument{
    name = <<"temperature">>,
    kind = gauge,
    unit = <<"celsius">>
  } = Gauge,
  ok.

gauge_set(_Config) ->
  Meter = instrument_meter:get_meter(<<"test">>),
  Gauge = instrument_meter:create_gauge(Meter, <<"cpu_usage">>),

  ok = instrument_meter:set(Gauge, 45.5),
  ok = instrument_meter:set(Gauge, 52.3),
  ok = instrument_meter:set(Gauge, 38.0, #{core => 0}),
  ok.

%% ============================================================================
%% Attributes Tests
%% ============================================================================

attributes_operations(_Config) ->
  %% New and put
  Attrs = instrument_attributes:new(),
  #{} = Attrs,

  Attrs2 = instrument_attributes:put(Attrs, key1, <<"value1">>),
  <<"value1">> = instrument_attributes:get(Attrs2, key1),

  %% From map
  Attrs3 = instrument_attributes:new(#{key2 => 42, key3 => true}),
  42 = instrument_attributes:get(Attrs3, key2),
  true = instrument_attributes:get(Attrs3, key3),

  %% Merge
  Merged = instrument_attributes:merge(Attrs2, Attrs3),
  <<"value1">> = instrument_attributes:get(Merged, key1),
  42 = instrument_attributes:get(Merged, key2),

  %% Remove
  Attrs4 = instrument_attributes:remove(Merged, key1),
  undefined = instrument_attributes:get(Attrs4, key1),

  %% To/from list
  List = instrument_attributes:to_list(Attrs3),
  true = is_list(List),
  Attrs5 = instrument_attributes:from_list(List),
  42 = instrument_attributes:get(Attrs5, key2),

  %% Validate
  {ok, _} = instrument_attributes:validate(#{key => <<"valid">>}),

  %% Hash
  Hash1 = instrument_attributes:hash(#{a => 1, b => 2}),
  Hash2 = instrument_attributes:hash(#{b => 2, a => 1}),
  Hash1 = Hash2,  %% Same hash regardless of order

  %% To label values
  LabelAttrs = instrument_attributes:new(#{method => <<"GET">>, status => 200}),
  [<<"GET">>, <<"200">>] = instrument_attributes:to_label_values(LabelAttrs, [method, status]),
  ok.

%% ============================================================================
%% New Test Cases - Metrics with Attributes
%% ============================================================================

counter_with_attributes_test(_Config) ->
  Meter = instrument_meter:get_meter(<<"attr_test">>),
  Counter = instrument_meter:create_counter(Meter, <<"attr_counter">>, #{
    description => <<"Counter with attributes">>
  }),

  %% Add without attributes
  ok = instrument_meter:add(Counter, 1),

  %% Add with various attributes
  ok = instrument_meter:add(Counter, 1, #{method => <<"GET">>}),
  ok = instrument_meter:add(Counter, 2, #{method => <<"POST">>}),
  ok = instrument_meter:add(Counter, 1, #{method => <<"GET">>, status => 200}),

  %% Should complete without error
  ok.

gauge_with_attributes_test(_Config) ->
  Meter = instrument_meter:get_meter(<<"attr_test">>),
  Gauge = instrument_meter:create_gauge(Meter, <<"attr_gauge">>, #{
    description => <<"Gauge with attributes">>
  }),

  %% Set without attributes
  ok = instrument_meter:set(Gauge, 10.0),

  %% Set with attributes
  ok = instrument_meter:set(Gauge, 25.5, #{cpu => 0}),
  ok = instrument_meter:set(Gauge, 30.2, #{cpu => 1}),
  ok = instrument_meter:set(Gauge, 15.0, #{cpu => 0, node => <<"a">>}),

  %% Should complete without error
  ok.

histogram_with_attributes_test(_Config) ->
  Meter = instrument_meter:get_meter(<<"attr_test">>),
  Histogram = instrument_meter:create_histogram(Meter, <<"attr_histogram">>, #{
    description => <<"Histogram with attributes">>,
    boundaries => [1, 5, 10, 50, 100]
  }),

  %% Record without attributes
  ok = instrument_meter:record(Histogram, 5.5),

  %% Record with attributes
  ok = instrument_meter:record(Histogram, 2.3, #{endpoint => <<"/api/users">>}),
  ok = instrument_meter:record(Histogram, 45.0, #{endpoint => <<"/api/orders">>}),
  ok = instrument_meter:record(Histogram, 150.0, #{endpoint => <<"/api/users">>, method => <<"POST">>}),

  %% Should complete without error
  ok.

attribute_cardinality_test(_Config) ->
  Meter = instrument_meter:get_meter(<<"cardinality_test">>),
  Counter = instrument_meter:create_counter(Meter, <<"cardinality_counter">>, #{}),

  %% Create many attribute combinations
  lists:foreach(fun(I) ->
    Attrs = #{
      user_id => integer_to_binary(I),
      method => case I rem 3 of
        0 -> <<"GET">>;
        1 -> <<"POST">>;
        2 -> <<"DELETE">>
      end,
      status => case I rem 5 of
        0 -> 200;
        1 -> 201;
        2 -> 400;
        3 -> 404;
        4 -> 500
      end
    },
    ok = instrument_meter:add(Counter, 1, Attrs)
  end, lists:seq(1, 50)),

  %% Should handle high cardinality without error
  ok.

unregister_instrument_test(_Config) ->
  Meter = instrument_meter:get_meter(<<"unregister_test">>),

  %% Create instruments
  Counter = instrument_meter:create_counter(Meter, <<"unreg_counter">>),
  Gauge = instrument_meter:create_gauge(Meter, <<"unreg_gauge">>),

  %% Verify they exist
  #otel_instrument{} = instrument_meter:get_instrument(<<"unreg_counter">>),
  #otel_instrument{} = instrument_meter:get_instrument(<<"unreg_gauge">>),

  %% Use them
  ok = instrument_meter:add(Counter, 10),
  ok = instrument_meter:set(Gauge, 42.0),

  %% Unregister one
  ok = instrument_meter:unregister_instrument(<<"unreg_counter">>),

  %% Counter should be gone
  undefined = instrument_meter:get_instrument(<<"unreg_counter">>),

  %% Gauge should still exist
  #otel_instrument{} = instrument_meter:get_instrument(<<"unreg_gauge">>),

  %% Unregister non-existent returns error
  {error, not_found} = instrument_meter:unregister_instrument(<<"non_existent">>),

  %% Can re-create after unregister
  NewCounter = instrument_meter:create_counter(Meter, <<"unreg_counter">>),
  #otel_instrument{} = NewCounter,
  ok = instrument_meter:add(NewCounter, 5),

  ok.

unregister_all_instruments_test(_Config) ->
  Meter = instrument_meter:get_meter(<<"unreg_all_test">>),

  %% Create multiple instruments
  _ = instrument_meter:create_counter(Meter, <<"bulk_counter1">>),
  _ = instrument_meter:create_counter(Meter, <<"bulk_counter2">>),
  _ = instrument_meter:create_gauge(Meter, <<"bulk_gauge">>),
  _ = instrument_meter:create_histogram(Meter, <<"bulk_histogram">>),

  %% Verify they exist
  Instruments = instrument_meter:list_instruments(),
  true = length(Instruments) >= 4,

  %% Unregister all
  ok = instrument_meter:unregister_all_instruments(),

  %% All should be gone
  [] = instrument_meter:list_instruments(),
  undefined = instrument_meter:get_instrument(<<"bulk_counter1">>),
  undefined = instrument_meter:get_instrument(<<"bulk_counter2">>),
  undefined = instrument_meter:get_instrument(<<"bulk_gauge">>),
  undefined = instrument_meter:get_instrument(<<"bulk_histogram">>),

  ok.

%% Test that unregistering an instrument also cleans up associated vec metrics
unregister_cleans_vec_metrics_test(_Config) ->
  Meter = instrument_meter:get_meter(<<"vec_cleanup_test">>),
  Counter = instrument_meter:create_counter(Meter, <<"cleanup_counter">>, #{}),

  %% Add with attributes to create vec metrics
  ok = instrument_meter:add(Counter, 1, #{method => <<"GET">>}),
  ok = instrument_meter:add(Counter, 2, #{method => <<"POST">>}),
  ok = instrument_meter:add(Counter, 3, #{method => <<"GET">>, status => 200}),

  %% Verify vec metrics were created by checking registry
  AllMetrics1 = instrument_registry:collect_all(),
  VecMetrics1 = [M || #{name := N} = M <- AllMetrics1,
                      is_tuple(N) andalso element(1, N) =:= otel_vec],
  true = length(VecMetrics1) >= 1,

  %% Unregister the instrument
  ok = instrument_meter:unregister_instrument(<<"cleanup_counter">>),

  %% Verify the instrument is gone
  undefined = instrument_meter:get_instrument(<<"cleanup_counter">>),

  %% Verify vec metrics were also cleaned up
  AllMetrics2 = instrument_registry:collect_all(),
  VecMetrics2 = [M || #{name := N} = M <- AllMetrics2,
                      is_tuple(N) andalso element(1, N) =:= otel_vec,
                      case N of
                        {otel_vec, Name} -> binary:match(Name, <<"cleanup_counter">>) =/= nomatch;
                        _ -> false
                      end],
  0 = length(VecMetrics2),

  %% Re-create the counter and verify it starts fresh (no stale state)
  Counter2 = instrument_meter:create_counter(Meter, <<"cleanup_counter">>, #{}),
  ok = instrument_meter:add(Counter2, 100, #{method => <<"GET">>}),

  %% Should be able to use it without issues
  ok = instrument_meter:add(Counter2, 50, #{method => <<"GET">>}),

  %% Cleanup
  ok = instrument_meter:unregister_instrument(<<"cleanup_counter">>),
  ok.

%% Test that concurrent attribute operations don't crash due to race conditions
concurrent_attribute_operations_test(_Config) ->
  Meter = instrument_meter:get_meter(<<"concurrent_test">>),
  Counter = instrument_meter:create_counter(Meter, <<"race_counter">>, #{}),

  Parent = self(),
  NumProcs = 100,

  %% Spawn many processes that all try to create the same attribute schema
  Pids = [spawn_link(fun() ->
    try
      %% All processes use the same attribute schema to maximize race chance
      ok = instrument_meter:add(Counter, 1, #{method => <<"GET">>, status => 200}),
      Parent ! {self(), ok}
    catch
      Class:Reason ->
        Parent ! {self(), {error, Class, Reason}}
    end
  end) || _ <- lists:seq(1, NumProcs)],

  %% Collect results
  Results = [receive {Pid, Result} -> Result after 5000 -> timeout end || Pid <- Pids],

  %% All should succeed (no crashes from race conditions)
  Errors = [R || R <- Results, R =/= ok],
  case Errors of
    [] -> ok;
    _ -> ct:fail({concurrent_operations_failed, Errors})
  end,

  %% Cleanup
  ok = instrument_meter:unregister_instrument(<<"race_counter">>),
  ok.

%% Test that description and unit are preserved when collecting metrics
description_unit_preserved_test(_Config) ->
  Meter = instrument_meter:get_meter(<<"desc_unit_test">>),

  %% Create counter with description and unit
  Counter = instrument_meter:create_counter(Meter, <<"preserved_counter">>, #{
    description => <<"My custom description">>,
    unit => <<"requests">>
  }),
  ok = instrument_meter:add(Counter, 10),

  %% Collect metrics
  Metrics = instrument_metrics_exporter:collect(),

  %% Find our counter (may have otel prefix)
  CounterMetrics = [M || #{name := N} = M <- Metrics,
                         binary:match(N, <<"preserved_counter">>) =/= nomatch],
  ?assert(length(CounterMetrics) >= 1),

  %% Verify description is preserved
  [CounterMetric | _] = CounterMetrics,
  Description = maps:get(description, CounterMetric, maps:get(help, CounterMetric, <<>>)),
  ?assertEqual(<<"My custom description">>, Description),

  %% Verify unit is preserved (not hardcoded "1")
  Unit = maps:get(unit, CounterMetric, <<"1">>),
  ?assertEqual(<<"requests">>, Unit),

  %% Cleanup
  ok = instrument_meter:unregister_instrument(<<"preserved_counter">>),
  ok.

%% ============================================================================
%% Temporality Tests (OTel Spec Compliance)
%% ============================================================================

%% Test creating counter with explicit cumulative temporality
temporality_option_cumulative_test(_Config) ->
  Meter = instrument_meter:get_meter(<<"temporality_test">>),

  %% Create counter with explicit cumulative temporality
  Counter = instrument_meter:create_counter(Meter, <<"cumulative_counter">>, #{
    description => <<"Counter with cumulative temporality">>,
    temporality => cumulative
  }),

  %% Verify instrument has cumulative temporality
  ?assertEqual(cumulative, Counter#otel_instrument.temporality),
  ?assertEqual(counter, Counter#otel_instrument.kind),

  ok = instrument_meter:add(Counter, 5),

  %% Cleanup
  ok = instrument_meter:unregister_instrument(<<"cumulative_counter">>),
  ok.

%% Test creating counter with delta temporality
temporality_option_delta_test(_Config) ->
  Meter = instrument_meter:get_meter(<<"temporality_test">>),

  %% Create counter with delta temporality
  Counter = instrument_meter:create_counter(Meter, <<"delta_counter">>, #{
    description => <<"Counter with delta temporality">>,
    temporality => delta
  }),

  %% Verify instrument has delta temporality
  ?assertEqual(delta, Counter#otel_instrument.temporality),
  ?assertEqual(counter, Counter#otel_instrument.kind),

  ok = instrument_meter:add(Counter, 10),

  %% Cleanup
  ok = instrument_meter:unregister_instrument(<<"delta_counter">>),
  ok.

%% Test that default temporality is cumulative (per OTel spec)
temporality_default_test(_Config) ->
  Meter = instrument_meter:get_meter(<<"temporality_test">>),

  %% Create counter without specifying temporality
  Counter = instrument_meter:create_counter(Meter, <<"default_temp_counter">>, #{
    description => <<"Counter with default temporality">>
  }),

  %% Default should be cumulative per OTel spec
  ?assertEqual(cumulative, Counter#otel_instrument.temporality),

  %% Also verify for histogram
  Histogram = instrument_meter:create_histogram(Meter, <<"default_temp_histogram">>, #{
    description => <<"Histogram with default temporality">>
  }),
  ?assertEqual(cumulative, Histogram#otel_instrument.temporality),

  %% Cleanup
  ok = instrument_meter:unregister_instrument(<<"default_temp_counter">>),
  ok = instrument_meter:unregister_instrument(<<"default_temp_histogram">>),
  ok.

%% Labeled up_down_counter previously crashed on negative deltas because the
%% labeled write path hardcoded counter-shaped storage.
add_negative_to_labeled_up_down_counter(_Config) ->
  Meter = instrument_meter:get_meter(<<"signed_updc_test">>),
  Counter = instrument_meter:create_up_down_counter(Meter, <<"signed_active">>),

  %% Establish a positive baseline at one label set.
  ok = instrument_meter:add(Counter, 5, #{a => <<"x">>}),

  %% Negative delta at the same label set — must not crash.
  ok = instrument_meter:add(Counter, -2, #{a => <<"x">>}),

  %% Rendered exposition must reflect 5 - 2 = 3.0 for {a="x"}.
  Output1 = instrument_prometheus:format(),
  ?assertNotEqual(nomatch,
                  binary:match(Output1, <<"signed_active_a{a=\"x\"} 3.0">>)),

  %% A negative-only label set must register and render as a negative gauge.
  ok = instrument_meter:add(Counter, -1, #{a => <<"y">>}),
  Output2 = instrument_prometheus:format(),
  ?assertNotEqual(nomatch,
                  binary:match(Output2, <<"signed_active_a{a=\"y\"} -1.0">>)),
  ok.

%% Regression: an unlabeled up_down_counter must honour negative deltas. The
%% unlabeled add path routed every value through inc_gauge, whose C sign guard
%% drops negatives, so add(C, -N) with no attributes was silently a no-op.
add_negative_to_unlabeled_up_down_counter(_Config) ->
  Meter = instrument_meter:get_meter(<<"unlabeled_updc_test">>),
  Counter = instrument_meter:create_up_down_counter(Meter, <<"unlabeled_conns">>),

  ok = instrument_meter:add(Counter, 5),
  ok = instrument_meter:add(Counter, -2),

  Output = instrument_prometheus:format(),
  ct:pal("unlabeled up_down_counter exposition:~n~s", [Output]),
  ?assertNotEqual(nomatch, binary:match(Output, <<"unlabeled_conns 3.0">>)),
  ok.
