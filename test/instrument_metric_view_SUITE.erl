%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_metric_view_SUITE).
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
  register_view_test/1,
  unregister_view_test/1,
  list_views_test/1,
  rename_metric_test/1,
  update_description_test/1,
  filter_attributes_test/1,
  wildcard_match_test/1,
  type_match_test/1,
  multiple_views_test/1,
  no_views_passthrough_test/1,
  histogram_view_boundaries_test/1
]).

all() ->
  [
    register_view_test,
    unregister_view_test,
    list_views_test,
    rename_metric_test,
    update_description_test,
    filter_attributes_test,
    wildcard_match_test,
    type_match_test,
    multiple_views_test,
    no_views_passthrough_test,
    histogram_view_boundaries_test
  ].

init_per_suite(Config) ->
  _ = application:ensure_all_started(crypto),
  ok = application:start(instrument),
  Config.

end_per_suite(_Config) ->
  ok = application:stop(instrument),
  ok.

init_per_testcase(_TestCase, Config) ->
  instrument_metric_view:clear(),
  Config.

end_per_testcase(_TestCase, _Config) ->
  instrument_metric_view:clear(),
  ok.

%% ============================================================================
%% Test Cases
%% ============================================================================

register_view_test(_Config) ->
  View = #metric_view{
    instrument_name = <<"test_counter">>,
    name = <<"renamed_counter">>
  },
  ok = instrument_metric_view:register(View),
  ?assertEqual([View], instrument_metric_view:list()),
  ok.

unregister_view_test(_Config) ->
  View1 = #metric_view{instrument_name = <<"counter1">>, name = <<"new_counter1">>},
  View2 = #metric_view{instrument_name = <<"counter2">>, name = <<"new_counter2">>},

  ok = instrument_metric_view:register(View1),
  ok = instrument_metric_view:register(View2),
  ?assertEqual(2, length(instrument_metric_view:list())),

  ok = instrument_metric_view:unregister(<<"counter1">>),
  ?assertEqual([View2], instrument_metric_view:list()),
  ok.

list_views_test(_Config) ->
  ?assertEqual([], instrument_metric_view:list()),

  View1 = #metric_view{instrument_name = <<"m1">>},
  View2 = #metric_view{instrument_name = <<"m2">>},
  View3 = #metric_view{instrument_name = <<"m3">>},

  ok = instrument_metric_view:register(View1),
  ok = instrument_metric_view:register(View2),
  ok = instrument_metric_view:register(View3),

  ?assertEqual(3, length(instrument_metric_view:list())),
  ok.

rename_metric_test(_Config) ->
  View = #metric_view{
    instrument_name = <<"original_name">>,
    name = <<"new_name">>
  },
  ok = instrument_metric_view:register(View),

  Metric = #{
    name => <<"original_name">>,
    description => <<"Test metric">>,
    type => counter,
    data_points => [#{attributes => #{}, value => 42, timestamp => 123}]
  },

  [Transformed] = instrument_metric_view:apply_views([Metric]),
  ?assertEqual(<<"new_name">>, maps:get(name, Transformed)),
  ok.

update_description_test(_Config) ->
  View = #metric_view{
    instrument_name = <<"test_metric">>,
    description = <<"Updated description">>
  },
  ok = instrument_metric_view:register(View),

  Metric = #{
    name => <<"test_metric">>,
    description => <<"Original description">>,
    type => gauge,
    data_points => []
  },

  [Transformed] = instrument_metric_view:apply_views([Metric]),
  ?assertEqual(<<"Updated description">>, maps:get(description, Transformed)),
  ok.

filter_attributes_test(_Config) ->
  View = #metric_view{
    instrument_name = <<"http_requests">>,
    attribute_keys = [<<"method">>, <<"status">>]
  },
  ok = instrument_metric_view:register(View),

  Metric = #{
    name => <<"http_requests">>,
    description => <<"HTTP request counter">>,
    type => counter,
    data_points => [
      #{
        attributes => #{
          <<"method">> => <<"GET">>,
          <<"status">> => <<"200">>,
          <<"path">> => <<"/api/users">>,
          <<"host">> => <<"localhost">>
        },
        value => 100,
        timestamp => 123
      }
    ]
  },

  [Transformed] = instrument_metric_view:apply_views([Metric]),
  [Point] = maps:get(data_points, Transformed),
  Attrs = maps:get(attributes, Point),

  ?assertEqual(<<"GET">>, maps:get(<<"method">>, Attrs)),
  ?assertEqual(<<"200">>, maps:get(<<"status">>, Attrs)),
  ?assertEqual(undefined, maps:get(<<"path">>, Attrs, undefined)),
  ?assertEqual(undefined, maps:get(<<"host">>, Attrs, undefined)),
  ok.

wildcard_match_test(_Config) ->
  %% View that matches all metrics
  View = #metric_view{
    instrument_name = '_',
    description = <<"All metrics get this description">>
  },
  ok = instrument_metric_view:register(View),

  Metric1 = #{name => <<"metric1">>, description => <<"Desc1">>, type => counter, data_points => []},
  Metric2 = #{name => <<"metric2">>, description => <<"Desc2">>, type => gauge, data_points => []},

  [T1, T2] = instrument_metric_view:apply_views([Metric1, Metric2]),
  ?assertEqual(<<"All metrics get this description">>, maps:get(description, T1)),
  ?assertEqual(<<"All metrics get this description">>, maps:get(description, T2)),
  ok.

type_match_test(_Config) ->
  %% View that only matches counters
  View = #metric_view{
    instrument_name = '_',
    instrument_type = counter,
    description = <<"Counter metric">>
  },
  ok = instrument_metric_view:register(View),

  CounterMetric = #{name => <<"my_counter">>, description => <<"Original">>, type => counter, data_points => []},
  GaugeMetric = #{name => <<"my_gauge">>, description => <<"Original">>, type => gauge, data_points => []},

  [TCounter, TGauge] = instrument_metric_view:apply_views([CounterMetric, GaugeMetric]),

  %% Counter should be transformed
  ?assertEqual(<<"Counter metric">>, maps:get(description, TCounter)),
  %% Gauge should be unchanged
  ?assertEqual(<<"Original">>, maps:get(description, TGauge)),
  ok.

multiple_views_test(_Config) ->
  %% First view renames
  View1 = #metric_view{
    instrument_name = <<"test_metric">>,
    name = <<"renamed_metric">>
  },
  %% Second view updates description
  View2 = #metric_view{
    instrument_name = <<"test_metric">>,
    description = <<"New description">>
  },

  ok = instrument_metric_view:register(View1),
  ok = instrument_metric_view:register(View2),

  Metric = #{
    name => <<"test_metric">>,
    description => <<"Old description">>,
    type => counter,
    data_points => []
  },

  [Transformed] = instrument_metric_view:apply_views([Metric]),

  %% Both views should be applied
  ?assertEqual(<<"renamed_metric">>, maps:get(name, Transformed)),
  ?assertEqual(<<"New description">>, maps:get(description, Transformed)),
  ok.

no_views_passthrough_test(_Config) ->
  %% With no views registered, metrics should pass through unchanged
  ?assertEqual([], instrument_metric_view:list()),

  Metric = #{
    name => <<"unchanged_metric">>,
    description => <<"Original description">>,
    type => histogram,
    data_points => [#{attributes => #{<<"key">> => <<"value">>}, value => 1.5, timestamp => 999}]
  },

  [Result] = instrument_metric_view:apply_views([Metric]),
  ?assertEqual(Metric, Result),
  ok.

%% Test that histogram view boundaries are applied when creating histogram
histogram_view_boundaries_test(_Config) ->
  %% Register view with custom boundaries BEFORE creating histogram
  CustomBoundaries = [1.0, 5.0, 10.0, 50.0, 100.0],
  View = #metric_view{
    instrument_name = <<"view_bounded_hist">>,
    boundaries = CustomBoundaries
  },
  ok = instrument_metric_view:register(View),

  %% Clean up any existing instrument
  _ = instrument_meter:unregister_instrument(<<"view_bounded_hist">>),

  %% Create histogram WITHOUT explicit boundaries - should use view boundaries
  Meter = instrument_meter:get_meter(<<"view_test">>),
  Histogram = instrument_meter:create_histogram(Meter, <<"view_bounded_hist">>, #{
    description => <<"Histogram with view boundaries">>
    %% Note: NO boundaries in Opts
  }),

  %% Record some values
  ok = instrument_meter:record(Histogram, 2.5),
  ok = instrument_meter:record(Histogram, 25.0),
  ok = instrument_meter:record(Histogram, 75.0),

  %% Get the underlying metric and check boundaries
  #otel_instrument{handle = Handle} = Histogram,
  ActualBoundaries = instrument_histogram:get_bucket_boundaries(Handle),

  %% Verify view boundaries were used
  ?assertEqual(CustomBoundaries, ActualBoundaries),

  %% Cleanup
  ok = instrument_meter:unregister_instrument(<<"view_bounded_hist">>),
  ok.
