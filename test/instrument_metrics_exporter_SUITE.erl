%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_metrics_exporter_SUITE).
-author("benoitc").

-export([
  all/0,
  init_per_suite/1,
  end_per_suite/1,
  init_per_testcase/2,
  end_per_testcase/2
]).

-export([
  register_unregister/1,
  collect_metrics/1,
  collect_labeled_metrics/1,
  console_exporter_text/1,
  console_exporter_json/1,
  console_labeled_text/1,
  console_labeled_json/1,
  otlp_exporter_init/1,
  flush/1,
  periodic_export/1,
  %% Metric name tests
  metric_name_atom_test/1,
  metric_name_binary_test/1,
  metric_name_vec_test/1,
  metric_name_otel_test/1,
  metric_name_otel_with_attrs_test/1
]).

all() ->
  [
    register_unregister,
    collect_metrics,
    collect_labeled_metrics,
    console_exporter_text,
    console_exporter_json,
    console_labeled_text,
    console_labeled_json,
    otlp_exporter_init,
    flush,
    periodic_export,
    %% Metric name tests
    metric_name_atom_test,
    metric_name_binary_test,
    metric_name_vec_test,
    metric_name_otel_test,
    metric_name_otel_with_attrs_test
  ].

init_per_suite(Config) ->
  _ = application:ensure_all_started(crypto),
  ok = application:start(instrument),
  Config.

end_per_suite(Config) ->
  ok = application:stop(instrument),
  Config.

init_per_testcase(_, Config) ->
  %% Unregister all exporters
  lists:foreach(fun(M) ->
    instrument_metrics_exporter:unregister(M)
  end, instrument_metrics_exporter:list()),
  Config.

end_per_testcase(_, _Config) ->
  ok.

%% ============================================================================
%% Tests
%% ============================================================================

register_unregister(_Config) ->
  %% Initially no exporters
  Initial = instrument_metrics_exporter:list(),

  %% Register console exporter
  ok = instrument_metrics_exporter:register(instrument_metrics_exporter_console:new()),
  true = lists:member(instrument_metrics_exporter_console, instrument_metrics_exporter:list()),

  %% Unregister
  ok = instrument_metrics_exporter:unregister(instrument_metrics_exporter_console),
  false = lists:member(instrument_metrics_exporter_console, instrument_metrics_exporter:list()),

  %% Should be back to initial state
  Initial = instrument_metrics_exporter:list(),
  ok.

collect_metrics(_Config) ->
  %% Create a counter
  Counter = instrument:new_counter(test_requests, [{help, "Test requests counter"}]),
  ok = instrument:inc_counter(Counter),
  ok = instrument:inc_counter(Counter),

  %% Create a gauge
  Gauge = instrument:new_gauge(test_connections, [{help, "Test connections gauge"}]),
  ok = instrument:set_gauge(Gauge, 42),

  %% Collect metrics
  Metrics = instrument_metrics_exporter:collect(),

  %% Verify counter is collected
  CounterMetrics = [M || #{name := N} = M <- Metrics, N =:= <<"test_requests">>],
  true = length(CounterMetrics) >= 1,

  %% Verify gauge is collected
  GaugeMetrics = [M || #{name := N} = M <- Metrics, N =:= <<"test_connections">>],
  true = length(GaugeMetrics) >= 1,
  ok.

collect_labeled_metrics(_Config) ->
  %% Create a labeled counter
  ok = instrument:new_counter_vec(http_requests, "HTTP requests", [method, status]),
  ok = instrument:inc_counter_vec(http_requests, [<<"GET">>, <<"200">>]),
  ok = instrument:inc_counter_vec(http_requests, [<<"GET">>, <<"200">>]),
  ok = instrument:inc_counter_vec(http_requests, [<<"POST">>, <<"201">>]),

  %% Create a labeled gauge
  ok = instrument:new_gauge_vec(active_sessions, "Active sessions", [region]),
  ok = instrument:set_gauge_vec(active_sessions, [<<"us-east">>], 100),
  ok = instrument:set_gauge_vec(active_sessions, [<<"eu-west">>], 75),

  %% Collect metrics
  Metrics = instrument_metrics_exporter:collect(),

  %% Verify labeled counter is collected
  HttpMetrics = [M || #{name := N} = M <- Metrics, N =:= <<"http_requests">>],
  true = length(HttpMetrics) >= 1,

  %% Verify labeled gauge is collected
  SessionMetrics = [M || #{name := N} = M <- Metrics, N =:= <<"active_sessions">>],
  true = length(SessionMetrics) >= 1,
  ok.

console_exporter_text(_Config) ->
  %% Register console exporter with text format
  ok = instrument_metrics_exporter:register(instrument_metrics_exporter_console:new(#{
    format => text,
    output => standard_io
  })),

  %% Create a metric
  Counter = instrument:new_counter(console_text_counter, [{help, "Test counter for console text"}]),
  ok = instrument:inc_counter(Counter),

  %% Flush to ensure export
  ok = instrument_metrics_exporter:flush(),
  ok.

console_exporter_json(_Config) ->
  %% Register console exporter with JSON format
  ok = instrument_metrics_exporter:register(instrument_metrics_exporter_console:new(#{
    format => json,
    output => standard_io
  })),

  %% Create metrics
  Counter = instrument:new_counter(console_json_counter, [{help, "JSON test counter"}]),
  ok = instrument:inc_counter(Counter),
  ok = instrument:inc_counter(Counter),

  Gauge = instrument:new_gauge(console_json_gauge, [{help, "JSON test gauge"}]),
  ok = instrument:set_gauge(Gauge, 123),

  %% Flush to ensure export
  ok = instrument_metrics_exporter:flush(),
  ok.

console_labeled_text(_Config) ->
  %% Register console exporter with text format
  ok = instrument_metrics_exporter:register(instrument_metrics_exporter_console:new(#{
    format => text,
    output => standard_io
  })),

  %% Create labeled metrics
  ok = instrument:new_counter_vec(api_requests, "API requests", [endpoint, method]),
  ok = instrument:inc_counter_vec(api_requests, [<<"/users">>, <<"GET">>]),
  ok = instrument:inc_counter_vec(api_requests, [<<"/users">>, <<"POST">>]),

  ok = instrument:new_gauge_vec(queue_size, "Queue size", [queue_name]),
  ok = instrument:set_gauge_vec(queue_size, [<<"orders">>], 42),

  %% Flush to ensure export
  ok = instrument_metrics_exporter:flush(),
  ok.

console_labeled_json(_Config) ->
  %% Register console exporter with JSON format
  ok = instrument_metrics_exporter:register(instrument_metrics_exporter_console:new(#{
    format => json,
    output => standard_io
  })),

  %% Create labeled histogram
  ok = instrument:new_histogram_vec(response_time, "Response time", [service], [0.1, 0.5, 1.0, 5.0]),
  ok = instrument:observe_histogram_vec(response_time, [<<"auth">>], 0.05),
  ok = instrument:observe_histogram_vec(response_time, [<<"auth">>], 0.3),
  ok = instrument:observe_histogram_vec(response_time, [<<"api">>], 0.8),

  %% Flush to ensure export
  ok = instrument_metrics_exporter:flush(),
  ok.

otlp_exporter_init(_Config) ->
  %% Test OTLP exporter initialization
  Config = #{endpoint => <<"http://localhost:4318">>},
  #{module := Mod, config := Cfg} = instrument_metrics_exporter_otlp:new(Config),
  instrument_metrics_exporter_otlp = Mod,
  <<"http://localhost:4318">> = maps:get(endpoint, Cfg),

  %% Test initialization with options
  {ok, State} = instrument_metrics_exporter_otlp:exporter_init(#{
    endpoint => "http://localhost:4318",
    compression => gzip,
    timeout => 5000
  }),

  %% Shutdown returns ok
  ok = instrument_metrics_exporter_otlp:exporter_shutdown(State),
  ok.

flush(_Config) ->
  %% Test flush with no exporters
  ok = instrument_metrics_exporter:flush(),

  %% Register console exporter
  ok = instrument_metrics_exporter:register(instrument_metrics_exporter_console:new()),

  %% Create metric and flush
  Counter = instrument:new_counter(flush_test_counter, [{help, "Flush test"}]),
  ok = instrument:inc_counter(Counter),
  ok = instrument_metrics_exporter:flush(),

  %% Shutdown
  ok = instrument_metrics_exporter:shutdown(),
  [] = instrument_metrics_exporter:list(),
  ok.

periodic_export(_Config) ->
  %% This test verifies that periodic export timer works
  %% We use a short interval for testing

  %% Register console exporter
  ok = instrument_metrics_exporter:register(instrument_metrics_exporter_console:new(#{
    format => text,
    output => standard_io
  })),

  %% Create a metric
  Counter = instrument:new_counter(periodic_counter, [{help, "Periodic test"}]),
  ok = instrument:inc_counter(Counter),

  %% Trigger manual export (since default interval is 60s)
  ok = instrument_metrics_exporter:export(),

  %% Small delay to allow async export to complete
  timer:sleep(100),
  ok.

%% ============================================================================
%% Metric Name Tests
%% ============================================================================

%% Test that atom metric names are correctly converted to binary
metric_name_atom_test(_Config) ->
  Counter = instrument:new_counter(my_atom_counter, [{help, "Atom name counter"}]),
  ok = instrument:inc_counter(Counter, 5),

  Metrics = instrument_metrics_exporter:collect(),
  CounterMetrics = [M || #{name := N} = M <- Metrics, N =:= <<"my_atom_counter">>],
  true = length(CounterMetrics) >= 1,

  [#{name := Name, data_points := [#{value := Value}]}] = CounterMetrics,
  <<"my_atom_counter">> = Name,
  5.0 = Value,
  ok.

%% Test that binary metric names are preserved
metric_name_binary_test(_Config) ->
  %% Use instrument_nif directly to create metric with binary name
  Gauge = instrument:new_gauge(<<"my_binary_gauge">>, [{help, "Binary name gauge"}]),
  ok = instrument:set_gauge(Gauge, 42),

  Metrics = instrument_metrics_exporter:collect(),
  GaugeMetrics = [M || #{name := N} = M <- Metrics, N =:= <<"my_binary_gauge">>],
  true = length(GaugeMetrics) >= 1,

  [#{name := Name, data_points := [#{value := Value}]}] = GaugeMetrics,
  <<"my_binary_gauge">> = Name,
  42.0 = Value,
  ok.

%% Test that vec metric names are correctly exported
metric_name_vec_test(_Config) ->
  ok = instrument:new_counter_vec(my_vec_counter, "Vec counter", [method, status]),
  ok = instrument:inc_counter_vec(my_vec_counter, [<<"GET">>, <<"200">>], 10),
  ok = instrument:inc_counter_vec(my_vec_counter, [<<"POST">>, <<"201">>], 5),

  Metrics = instrument_metrics_exporter:collect(),
  VecMetrics = [M || #{name := N} = M <- Metrics, N =:= <<"my_vec_counter">>],
  true = length(VecMetrics) >= 1,

  [#{name := Name, data_points := DataPoints}] = VecMetrics,
  <<"my_vec_counter">> = Name,

  %% Should have 2 data points with different attributes
  true = length(DataPoints) >= 2,

  %% Verify attributes are present
  Attrs = [maps:get(attributes, DP) || DP <- DataPoints],
  true = lists:any(fun(A) -> maps:get(<<"method">>, A, undefined) =:= <<"GET">> end, Attrs),
  true = lists:any(fun(A) -> maps:get(<<"method">>, A, undefined) =:= <<"POST">> end, Attrs),
  ok.

%% Test that OTel meter metric names are correctly exported
metric_name_otel_test(_Config) ->
  Meter = instrument_meter:get_meter(<<"test_service">>),
  Counter = instrument_meter:create_counter(Meter, <<"otel_request_count">>, #{
    description => <<"OTel request counter">>
  }),
  ok = instrument_meter:add(Counter, 100),

  Metrics = instrument_metrics_exporter:collect(),

  %% OTel metrics use tuple names internally, but should export as readable names
  %% The internal name is {otel, <<"otel_request_count">>}
  OtelMetrics = [M || #{name := N} = M <- Metrics,
                      N =:= <<"{otel,<<\"otel_request_count\">>}">> orelse
                      N =:= <<"otel_request_count">> orelse
                      binary:match(N, <<"otel_request_count">>) =/= nomatch],

  %% Should find the metric
  true = length(OtelMetrics) >= 1,
  ok.

%% Test that OTel meter metrics with attributes have correct names
metric_name_otel_with_attrs_test(_Config) ->
  Meter = instrument_meter:get_meter(<<"attr_service">>),
  Counter = instrument_meter:create_counter(Meter, <<"otel_attr_counter">>, #{
    description => <<"OTel counter with attributes">>
  }),

  %% Add with different attribute sets
  ok = instrument_meter:add(Counter, 1, #{method => <<"GET">>}),
  ok = instrument_meter:add(Counter, 2, #{method => <<"POST">>}),
  ok = instrument_meter:add(Counter, 3, #{method => <<"GET">>, status => 200}),

  Metrics = instrument_metrics_exporter:collect(),

  %% The vec metrics created for attributes should have distinct names
  %% Find all metrics related to otel_attr_counter
  AttrMetrics = [M || #{name := N} = M <- Metrics,
                      binary:match(N, <<"otel_attr_counter">>) =/= nomatch],

  %% Should have created metrics for the different attribute schemas
  true = length(AttrMetrics) >= 1,
  ok.
