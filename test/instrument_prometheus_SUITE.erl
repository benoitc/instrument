%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.
-module(instrument_prometheus_SUITE).
-author("benoitc").

-include_lib("common_test/include/ct.hrl").

%% API
-export([
  all/0,
  groups/0,
  init_per_suite/1,
  end_per_suite/1,
  init_per_testcase/2,
  end_per_testcase/2
]).

%% VEC API tests
-export([
  counter_vec_basic/1,
  counter_vec_with_labels_function/1,
  gauge_vec_basic/1,
  histogram_vec_basic/1
]).

%% Prometheus format tests
-export([
  prometheus_content_type/1,
  prometheus_counter_format/1,
  prometheus_counter_vec_format/1,
  prometheus_gauge_format/1,
  prometheus_gauge_vec_format/1,
  prometheus_histogram_format/1,
  prometheus_histogram_vec_format/1,
  prometheus_label_escaping/1,
  prometheus_meter_counter/1,
  prometheus_meter_gauge/1,
  prometheus_meter_histogram/1
]).

all() ->
  [
    {group, vec_api},
    {group, prometheus_format}
  ].

groups() ->
  [
    {vec_api, [], [
      counter_vec_basic,
      counter_vec_with_labels_function,
      gauge_vec_basic,
      histogram_vec_basic
    ]},
    {prometheus_format, [], [
      prometheus_content_type,
      prometheus_counter_format,
      prometheus_counter_vec_format,
      prometheus_gauge_format,
      prometheus_gauge_vec_format,
      prometheus_histogram_format,
      prometheus_histogram_vec_format,
      prometheus_label_escaping,
      prometheus_meter_counter,
      prometheus_meter_gauge,
      prometheus_meter_histogram
    ]}
  ].

init_per_suite(Config) ->
  ok = application:start(instrument),
  Config.

end_per_suite(Config) ->
  ok = application:stop(instrument),
  Config.

init_per_testcase(_, Config) ->
  ok = instrument:unregister_all(),
  ok = instrument_meter:unregister_all_instruments(),
  timer:sleep(100),
  Config.

end_per_testcase(_, _Config) ->
  ok = instrument:unregister_all(),
  ok = instrument_meter:unregister_all_instruments(),
  timer:sleep(100),
  ok.

%% VEC API tests

counter_vec_basic(_Config) ->
  ok = instrument:new_counter_vec(http_requests, "Total HTTP requests", [method, status]),
  ok = instrument:inc_counter_vec(http_requests, [<<"GET">>, <<"200">>]),
  ok = instrument:inc_counter_vec(http_requests, [<<"POST">>, <<"201">>], 5),
  1.0 = instrument:get_counter_vec(http_requests, [<<"GET">>, <<"200">>]),
  5.0 = instrument:get_counter_vec(http_requests, [<<"POST">>, <<"201">>]),
  ok.

counter_vec_with_labels_function(_Config) ->
  ok = instrument:new_counter_vec(api_calls, "API calls", [endpoint]),
  GetUsers = instrument:labels(api_calls, [<<"/users">>]),
  ok = instrument:inc_counter(GetUsers),
  ok = instrument:inc_counter(GetUsers, 10),
  11.0 = instrument:get_counter(GetUsers),
  ok.

gauge_vec_basic(_Config) ->
  ok = instrument:new_gauge_vec(active_connections, "Active connections", [server]),
  ok = instrument:set_gauge_vec(active_connections, [<<"server1">>], 10),
  ok = instrument:inc_gauge_vec(active_connections, [<<"server1">>], 5),
  ok = instrument:dec_gauge_vec(active_connections, [<<"server1">>], 3),
  12.0 = instrument:get_gauge_vec(active_connections, [<<"server1">>]),
  ok.

histogram_vec_basic(_Config) ->
  ok = instrument:new_histogram_vec(request_latency, "Request latency", [endpoint], [0.1, 0.5, 1.0]),
  ok = instrument:observe_histogram_vec(request_latency, [<<"/api">>], 0.05),
  ok = instrument:observe_histogram_vec(request_latency, [<<"/api">>], 0.3),
  ok = instrument:observe_histogram_vec(request_latency, [<<"/api">>], 0.8),
  #{count := Count, sum := Sum} = instrument:get_histogram_vec(request_latency, [<<"/api">>]),
  true = (Count >= 3.0 andalso Count =< 3.0),
  true = (Sum > 1.14 andalso Sum < 1.16),
  ok.

%% Prometheus format tests

prometheus_content_type(_Config) ->
  <<"text/plain; version=0.0.4; charset=utf-8">> = instrument_prometheus:content_type(),
  ok.

prometheus_counter_format(_Config) ->
  _ = instrument:new_counter(simple_counter, "A simple counter"),
  ok = instrument:inc_counter(simple_counter, 42),
  Output = instrument_prometheus:format(),
  true = binary:match(Output, <<"# HELP simple_counter_total A simple counter">>) =/= nomatch,
  true = binary:match(Output, <<"# TYPE simple_counter_total counter">>) =/= nomatch,
  true = binary:match(Output, <<"simple_counter_total 42">>) =/= nomatch,
  ok.

prometheus_counter_vec_format(_Config) ->
  ok = instrument:new_counter_vec(http_requests, "Total requests", [method]),
  ok = instrument:inc_counter_vec(http_requests, [<<"GET">>], 100),
  ok = instrument:inc_counter_vec(http_requests, [<<"POST">>], 50),
  Output = instrument_prometheus:format(),
  true = binary:match(Output, <<"# HELP http_requests_total Total requests">>) =/= nomatch,
  true = binary:match(Output, <<"# TYPE http_requests_total counter">>) =/= nomatch,
  true = binary:match(Output, <<"http_requests_total{method=\"GET\"} 100">>) =/= nomatch,
  true = binary:match(Output, <<"http_requests_total{method=\"POST\"} 50">>) =/= nomatch,
  ok.

prometheus_gauge_format(_Config) ->
  _ = instrument:new_gauge(temperature, "Current temperature"),
  ok = instrument:set_gauge(temperature, 23.5),
  Output = instrument_prometheus:format(),
  true = binary:match(Output, <<"# HELP temperature Current temperature">>) =/= nomatch,
  true = binary:match(Output, <<"# TYPE temperature gauge">>) =/= nomatch,
  true = binary:match(Output, <<"temperature 23.5">>) =/= nomatch,
  ok.

prometheus_gauge_vec_format(_Config) ->
  ok = instrument:new_gauge_vec(pool_size, "Connection pool size", [pool]),
  ok = instrument:set_gauge_vec(pool_size, [<<"main">>], 10),
  ok = instrument:set_gauge_vec(pool_size, [<<"backup">>], 5),
  Output = instrument_prometheus:format(),
  true = binary:match(Output, <<"# HELP pool_size Connection pool size">>) =/= nomatch,
  true = binary:match(Output, <<"# TYPE pool_size gauge">>) =/= nomatch,
  true = binary:match(Output, <<"pool_size{pool=\"main\"} 10">>) =/= nomatch,
  true = binary:match(Output, <<"pool_size{pool=\"backup\"} 5">>) =/= nomatch,
  ok.

prometheus_histogram_format(_Config) ->
  _ = instrument:new_histogram(latency, "Request latency", [0.1, 0.5, 1.0]),
  ok = instrument:observe_histogram(latency, 0.05),
  ok = instrument:observe_histogram(latency, 0.3),
  Output = instrument_prometheus:format(),
  true = binary:match(Output, <<"# HELP latency Request latency">>) =/= nomatch,
  true = binary:match(Output, <<"# TYPE latency histogram">>) =/= nomatch,
  true = binary:match(Output, <<"latency_bucket{le=\"0.1\"} 1">>) =/= nomatch,
  true = binary:match(Output, <<"latency_bucket{le=\"0.5\"} 2">>) =/= nomatch,
  true = binary:match(Output, <<"latency_sum">>) =/= nomatch,
  true = binary:match(Output, <<"latency_count 2">>) =/= nomatch,
  ok.

prometheus_histogram_vec_format(_Config) ->
  ok = instrument:new_histogram_vec(api_latency, "API latency", [endpoint], [0.1, 0.5]),
  ok = instrument:observe_histogram_vec(api_latency, [<<"/users">>], 0.05),
  ok = instrument:observe_histogram_vec(api_latency, [<<"/users">>], 0.3),
  Output = instrument_prometheus:format(),
  true = binary:match(Output, <<"# HELP api_latency API latency">>) =/= nomatch,
  true = binary:match(Output, <<"# TYPE api_latency histogram">>) =/= nomatch,
  true = binary:match(Output, <<"api_latency_bucket{endpoint=\"/users\",le=\"0.1\"} 1">>) =/= nomatch,
  true = binary:match(Output, <<"api_latency_bucket{endpoint=\"/users\",le=\"0.5\"} 2">>) =/= nomatch,
  ok.

prometheus_label_escaping(_Config) ->
  ok = instrument:new_counter_vec(escaped_metric, "Test escaping", [label]),
  ok = instrument:inc_counter_vec(escaped_metric, [<<"value with \"quotes\"">>]),
  ok = instrument:inc_counter_vec(escaped_metric, [<<"value\\with\\backslashes">>]),
  ok = instrument:inc_counter_vec(escaped_metric, [<<"value\nwith\nnewlines">>]),
  Output = instrument_prometheus:format(),
  true = binary:match(Output, <<"label=\"value with \\\"quotes\\\"\"">>)  =/= nomatch,
  true = binary:match(Output, <<"label=\"value\\\\with\\\\backslashes\"">>)  =/= nomatch,
  true = binary:match(Output, <<"label=\"value\\nwith\\nnewlines\"">>)  =/= nomatch,
  ok.

%% Meter integration tests

prometheus_meter_counter(_Config) ->
  Meter = instrument_meter:get_meter(<<"prom_test">>),
  Counter = instrument_meter:create_counter(Meter, <<"meter_requests">>, #{
    description => <<"Meter counter">>
  }),
  ok = instrument_meter:add(Counter, 100),
  ok = instrument_meter:add(Counter, 50),

  Output = instrument_prometheus:format(),
  %% Verify base metric appears
  true = binary:match(Output, <<"meter_requests">>) =/= nomatch,
  ok.

prometheus_meter_gauge(_Config) ->
  Meter = instrument_meter:get_meter(<<"prom_test">>),
  Gauge = instrument_meter:create_gauge(Meter, <<"meter_temperature">>, #{
    description => <<"Meter gauge">>
  }),
  ok = instrument_meter:set(Gauge, 23.5),

  Output = instrument_prometheus:format(),
  true = binary:match(Output, <<"meter_temperature">>) =/= nomatch,
  true = binary:match(Output, <<"23.5">>) =/= nomatch,
  ok.

prometheus_meter_histogram(_Config) ->
  Meter = instrument_meter:get_meter(<<"prom_test">>),
  Histogram = instrument_meter:create_histogram(Meter, <<"meter_latency">>, #{
    description => <<"Meter histogram">>,
    boundaries => [0.1, 0.5, 1.0]
  }),
  ok = instrument_meter:record(Histogram, 0.3),
  ok = instrument_meter:record(Histogram, 0.7),

  Output = instrument_prometheus:format(),
  true = binary:match(Output, <<"meter_latency_bucket">>) =/= nomatch,
  true = binary:match(Output, <<"meter_latency_count">>) =/= nomatch,
  ok.
