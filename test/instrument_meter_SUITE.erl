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
  attribute_cardinality_test/1
]).

-include("instrument_otel.hrl").

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
    attribute_cardinality_test
  ].

init_per_suite(Config) ->
  ok = application:start(instrument),
  Config.

end_per_suite(Config) ->
  ok = application:stop(instrument),
  Config.

init_per_testcase(_, Config) ->
  _ = instrument:unregister_all(),
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
