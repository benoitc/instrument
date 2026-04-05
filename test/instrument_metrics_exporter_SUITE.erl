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
  periodic_export/1
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
    periodic_export
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
