%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_config_SUITE).
-author("benoitc").

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
  all/0,
  init_per_suite/1,
  end_per_suite/1,
  init_per_testcase/2,
  end_per_testcase/2
]).

-export([
  init_test/1,
  get_set_test/1,
  service_name_env_test/1,
  sampler_always_on_test/1,
  sampler_always_off_test/1,
  sampler_traceidratio_test/1,
  sampler_parentbased_test/1,
  propagators_env_test/1,
  batch_processor_config_test/1,
  otlp_endpoint_test/1,
  otlp_signal_endpoints_test/1,
  log_level_test/1
]).

all() ->
  [
    init_test,
    get_set_test,
    service_name_env_test,
    sampler_always_on_test,
    sampler_always_off_test,
    sampler_traceidratio_test,
    sampler_parentbased_test,
    propagators_env_test,
    batch_processor_config_test,
    otlp_endpoint_test,
    otlp_signal_endpoints_test,
    log_level_test
  ].

init_per_suite(Config) ->
  _ = application:ensure_all_started(crypto),
  Config.

end_per_suite(_Config) ->
  ok.

init_per_testcase(_TestCase, Config) ->
  %% Clear all OTEL env vars
  clear_otel_env(),
  ok = application:start(instrument),
  Config.

end_per_testcase(_TestCase, _Config) ->
  ok = application:stop(instrument),
  clear_otel_env(),
  ok.

clear_otel_env() ->
  EnvVars = [
    "OTEL_SERVICE_NAME",
    "OTEL_TRACES_SAMPLER",
    "OTEL_TRACES_SAMPLER_ARG",
    "OTEL_PROPAGATORS",
    "OTEL_BSP_SCHEDULE_DELAY",
    "OTEL_BSP_MAX_QUEUE_SIZE",
    "OTEL_BSP_MAX_EXPORT_BATCH_SIZE",
    "OTEL_EXPORTER_OTLP_ENDPOINT",
    "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
    "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT",
    "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT",
    "OTEL_LOG_LEVEL"
  ],
  lists:foreach(fun(Var) -> os:unsetenv(Var) end, EnvVars).

%% ============================================================================
%% Test Cases
%% ============================================================================

init_test(_Config) ->
  %% init() should have been called by application start
  ?assertEqual(undefined, instrument_config:get_service_name()),
  ok.

get_set_test(_Config) ->
  ?assertEqual(undefined, instrument_config:get(custom_key)),
  ?assertEqual(default, instrument_config:get(custom_key, default)),

  ok = instrument_config:set(custom_key, <<"value">>),
  ?assertEqual(<<"value">>, instrument_config:get(custom_key)),
  ok.

service_name_env_test(_Config) ->
  ok = application:stop(instrument),
  os:putenv("OTEL_SERVICE_NAME", "my-service"),
  ok = application:start(instrument),

  ?assertEqual(<<"my-service">>, instrument_config:get_service_name()),
  ok.

sampler_always_on_test(_Config) ->
  ok = application:stop(instrument),
  os:putenv("OTEL_TRACES_SAMPLER", "always_on"),
  ok = application:start(instrument),

  ?assertEqual({instrument_sampler_always_on, #{}}, instrument_config:get_sampler()),
  ok.

sampler_always_off_test(_Config) ->
  ok = application:stop(instrument),
  os:putenv("OTEL_TRACES_SAMPLER", "always_off"),
  ok = application:start(instrument),

  ?assertEqual({instrument_sampler_always_off, #{}}, instrument_config:get_sampler()),
  ok.

sampler_traceidratio_test(_Config) ->
  ok = application:stop(instrument),
  os:putenv("OTEL_TRACES_SAMPLER", "traceidratio"),
  os:putenv("OTEL_TRACES_SAMPLER_ARG", "0.5"),
  ok = application:start(instrument),

  ?assertEqual({instrument_sampler_probability, #{ratio => 0.5}},
               instrument_config:get_sampler()),
  ok.

sampler_parentbased_test(_Config) ->
  ok = application:stop(instrument),
  os:putenv("OTEL_TRACES_SAMPLER", "parentbased_always_on"),
  ok = application:start(instrument),

  ?assertEqual({instrument_sampler_parent_based, #{root => instrument_sampler_always_on}},
               instrument_config:get_sampler()),
  ok.

propagators_env_test(_Config) ->
  ok = application:stop(instrument),
  os:putenv("OTEL_PROPAGATORS", "tracecontext,baggage"),
  ok = application:start(instrument),

  ?assertEqual([instrument_propagator_tracecontext, instrument_propagator_baggage],
               instrument_config:get_propagators()),

  %% Verify propagators were actually applied
  ?assertEqual([instrument_propagator_tracecontext, instrument_propagator_baggage],
               instrument_propagator:list()),
  ok.

batch_processor_config_test(_Config) ->
  ok = application:stop(instrument),
  os:putenv("OTEL_BSP_SCHEDULE_DELAY", "1000"),
  os:putenv("OTEL_BSP_MAX_QUEUE_SIZE", "5000"),
  os:putenv("OTEL_BSP_MAX_EXPORT_BATCH_SIZE", "256"),
  ok = application:start(instrument),

  Config = instrument_config:get_batch_processor_config(),
  ?assertEqual(1000, maps:get(schedule_delay, Config)),
  ?assertEqual(5000, maps:get(max_queue_size, Config)),
  ?assertEqual(256, maps:get(max_export_batch_size, Config)),
  ok.

otlp_endpoint_test(_Config) ->
  ok = application:stop(instrument),
  os:putenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4317"),
  ok = application:start(instrument),

  ?assertEqual(<<"http://localhost:4317">>, instrument_config:get_otlp_endpoint()),

  %% Signal-specific endpoints should fall back to main endpoint
  ?assertEqual(<<"http://localhost:4317">>, instrument_config:get_otlp_endpoint(traces)),
  ?assertEqual(<<"http://localhost:4317">>, instrument_config:get_otlp_endpoint(metrics)),
  ?assertEqual(<<"http://localhost:4317">>, instrument_config:get_otlp_endpoint(logs)),
  ok.

otlp_signal_endpoints_test(_Config) ->
  ok = application:stop(instrument),
  os:putenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4317"),
  os:putenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "http://traces:4317"),
  os:putenv("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT", "http://metrics:4317"),
  ok = application:start(instrument),

  %% Signal-specific endpoints take precedence
  ?assertEqual(<<"http://traces:4317">>, instrument_config:get_otlp_endpoint(traces)),
  ?assertEqual(<<"http://metrics:4317">>, instrument_config:get_otlp_endpoint(metrics)),
  %% Logs falls back to main endpoint
  ?assertEqual(<<"http://localhost:4317">>, instrument_config:get_otlp_endpoint(logs)),
  ok.

log_level_test(_Config) ->
  ok = application:stop(instrument),
  os:putenv("OTEL_LOG_LEVEL", "debug"),
  ok = application:start(instrument),
  ?assertEqual(debug, instrument_config:get_log_level()),

  ok = application:stop(instrument),
  os:putenv("OTEL_LOG_LEVEL", "warning"),
  ok = application:start(instrument),
  ?assertEqual(warning, instrument_config:get_log_level()),

  ok = application:stop(instrument),
  os:putenv("OTEL_LOG_LEVEL", "warn"),
  ok = application:start(instrument),
  ?assertEqual(warning, instrument_config:get_log_level()),
  ok.
