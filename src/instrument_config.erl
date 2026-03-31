%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc SDK configuration from environment variables.
%%
%% This module reads OpenTelemetry SDK configuration from OTEL_*
%% environment variables and applies them to the instrument library.
%%
%% == Supported Environment Variables ==
%% - `OTEL_SERVICE_NAME' - Service name for resource
%% - `OTEL_TRACES_SAMPLER' - Sampler to use (always_on, always_off, traceidratio, parentbased_always_on, etc.)
%% - `OTEL_TRACES_SAMPLER_ARG' - Sampler argument (e.g., probability for traceidratio)
%% - `OTEL_PROPAGATORS' - Comma-separated list of propagators
%% - `OTEL_BSP_SCHEDULE_DELAY' - Batch span processor delay in ms
%% - `OTEL_BSP_MAX_QUEUE_SIZE' - Max queue size for batch processor
%% - `OTEL_BSP_MAX_EXPORT_BATCH_SIZE' - Max batch size for export
%% - `OTEL_EXPORTER_OTLP_ENDPOINT' - OTLP exporter endpoint
%% - `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT' - OTLP traces endpoint
%% - `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT' - OTLP metrics endpoint
%% - `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT' - OTLP logs endpoint
%% - `OTEL_LOG_LEVEL' - Log level (debug, info, warning, error)
-module(instrument_config).
-author("benoitc").

-compile({no_auto_import,[get/1]}).

-export([
  init/0,
  get/1,
  get/2,
  set/2,
  get_service_name/0,
  get_sampler/0,
  get_propagators/0,
  get_batch_processor_config/0,
  get_otlp_endpoint/0,
  get_otlp_endpoint/1,
  get_log_level/0
]).

-define(CONFIG_KEY, '$instrument_config').

%% ============================================================================
%% API
%% ============================================================================

%% @doc Initializes configuration from environment variables.
-spec init() -> ok.
init() ->
  Config = #{
    service_name => read_service_name(),
    sampler => read_sampler(),
    propagators => read_propagators(),
    batch_processor => read_batch_processor_config(),
    otlp_endpoint => read_otlp_endpoint(),
    otlp_traces_endpoint => read_otlp_traces_endpoint(),
    otlp_metrics_endpoint => read_otlp_metrics_endpoint(),
    otlp_logs_endpoint => read_otlp_logs_endpoint(),
    log_level => read_log_level()
  },
  persistent_term:put(?CONFIG_KEY, Config),
  apply_config(Config),
  ok.

%% @doc Gets a configuration value.
-spec get(atom()) -> term() | undefined.
get(Key) ->
  get(Key, undefined).

%% @doc Gets a configuration value with default.
-spec get(atom(), term()) -> term().
get(Key, Default) ->
  Config = persistent_term:get(?CONFIG_KEY, #{}),
  maps:get(Key, Config, Default).

%% @doc Sets a configuration value.
-spec set(atom(), term()) -> ok.
set(Key, Value) ->
  Config = persistent_term:get(?CONFIG_KEY, #{}),
  NewConfig = maps:put(Key, Value, Config),
  persistent_term:put(?CONFIG_KEY, NewConfig),
  ok.

%% @doc Gets the service name.
-spec get_service_name() -> binary() | undefined.
get_service_name() ->
  get(service_name).

%% @doc Gets the configured sampler.
-spec get_sampler() -> {module(), term()} | undefined.
get_sampler() ->
  get(sampler).

%% @doc Gets the configured propagators.
-spec get_propagators() -> [module()] | undefined.
get_propagators() ->
  get(propagators).

%% @doc Gets batch processor configuration.
-spec get_batch_processor_config() -> map().
get_batch_processor_config() ->
  get(batch_processor, #{}).

%% @doc Gets the OTLP endpoint.
-spec get_otlp_endpoint() -> binary() | undefined.
get_otlp_endpoint() ->
  get(otlp_endpoint).

%% @doc Gets a specific OTLP endpoint (traces, metrics, logs).
-spec get_otlp_endpoint(traces | metrics | logs) -> binary() | undefined.
get_otlp_endpoint(traces) ->
  case get(otlp_traces_endpoint) of
    undefined -> get(otlp_endpoint);
    Endpoint -> Endpoint
  end;
get_otlp_endpoint(metrics) ->
  case get(otlp_metrics_endpoint) of
    undefined -> get(otlp_endpoint);
    Endpoint -> Endpoint
  end;
get_otlp_endpoint(logs) ->
  case get(otlp_logs_endpoint) of
    undefined -> get(otlp_endpoint);
    Endpoint -> Endpoint
  end.

%% @doc Gets the log level.
-spec get_log_level() -> debug | info | warning | error | undefined.
get_log_level() ->
  get(log_level).

%% ============================================================================
%% Internal Functions
%% ============================================================================

read_service_name() ->
  case os:getenv("OTEL_SERVICE_NAME") of
    false -> undefined;
    Value -> list_to_binary(Value)
  end.

read_sampler() ->
  SamplerName = os:getenv("OTEL_TRACES_SAMPLER"),
  SamplerArg = os:getenv("OTEL_TRACES_SAMPLER_ARG"),
  parse_sampler(SamplerName, SamplerArg).

parse_sampler(false, _) -> undefined;
parse_sampler("always_on", _) ->
  {instrument_sampler_always_on, #{}};
parse_sampler("always_off", _) ->
  {instrument_sampler_always_off, #{}};
parse_sampler("traceidratio", false) ->
  {instrument_sampler_probability, #{ratio => 1.0}};
parse_sampler("traceidratio", Arg) ->
  Prob = parse_float(Arg, 1.0),
  {instrument_sampler_probability, #{ratio => Prob}};
parse_sampler("parentbased_always_on", _) ->
  {instrument_sampler_parent_based, #{root => instrument_sampler_always_on}};
parse_sampler("parentbased_always_off", _) ->
  {instrument_sampler_parent_based, #{root => instrument_sampler_always_off}};
parse_sampler("parentbased_traceidratio", false) ->
  {instrument_sampler_parent_based, #{
    root => instrument_sampler_probability,
    root_config => #{ratio => 1.0}
  }};
parse_sampler("parentbased_traceidratio", Arg) ->
  Prob = parse_float(Arg, 1.0),
  {instrument_sampler_parent_based, #{
    root => instrument_sampler_probability,
    root_config => #{ratio => Prob}
  }};
parse_sampler(_, _) -> undefined.

read_propagators() ->
  case os:getenv("OTEL_PROPAGATORS") of
    false -> undefined;
    Value ->
      Names = string:tokens(Value, ","),
      lists:filtermap(fun parse_propagator/1, Names)
  end.

parse_propagator("tracecontext") -> {true, instrument_propagator_tracecontext};
parse_propagator("baggage") -> {true, instrument_propagator_baggage};
%% b3 and b3multi propagators are not yet implemented
parse_propagator("b3") -> false;
parse_propagator("b3multi") -> false;
parse_propagator(_) -> false.

read_batch_processor_config() ->
  Config = #{},
  Config1 = maybe_add_int("OTEL_BSP_SCHEDULE_DELAY", schedule_delay, Config),
  Config2 = maybe_add_int("OTEL_BSP_MAX_QUEUE_SIZE", max_queue_size, Config1),
  maybe_add_int("OTEL_BSP_MAX_EXPORT_BATCH_SIZE", max_export_batch_size, Config2).

maybe_add_int(EnvVar, Key, Config) ->
  case os:getenv(EnvVar) of
    false -> Config;
    Value ->
      case catch list_to_integer(Value) of
        Int when is_integer(Int) -> maps:put(Key, Int, Config);
        _ -> Config
      end
  end.

read_otlp_endpoint() ->
  case os:getenv("OTEL_EXPORTER_OTLP_ENDPOINT") of
    false -> undefined;
    Value -> list_to_binary(Value)
  end.

read_otlp_traces_endpoint() ->
  case os:getenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT") of
    false -> undefined;
    Value -> list_to_binary(Value)
  end.

read_otlp_metrics_endpoint() ->
  case os:getenv("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT") of
    false -> undefined;
    Value -> list_to_binary(Value)
  end.

read_otlp_logs_endpoint() ->
  case os:getenv("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT") of
    false -> undefined;
    Value -> list_to_binary(Value)
  end.

read_log_level() ->
  case os:getenv("OTEL_LOG_LEVEL") of
    false -> undefined;
    "debug" -> debug;
    "info" -> info;
    "warning" -> warning;
    "warn" -> warning;
    "error" -> error;
    _ -> undefined
  end.

parse_float(Value, Default) ->
  case catch list_to_float(Value) of
    F when is_float(F) -> F;
    _ ->
      case catch list_to_integer(Value) of
        I when is_integer(I) -> float(I);
        _ -> Default
      end
  end.

apply_config(Config) ->
  apply_sampler(Config),
  apply_propagators(Config),
  ok.

apply_sampler(#{sampler := {Module, Opts}}) ->
  instrument_sampler:set_sampler(Module, Opts);
apply_sampler(_) ->
  ok.

apply_propagators(#{propagators := Propagators}) when is_list(Propagators), Propagators =/= [] ->
  instrument_propagator:set_propagators(Propagators);
apply_propagators(_) ->
  ok.
