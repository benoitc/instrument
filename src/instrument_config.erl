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
  get_service_version/0,
  get_resource_config/0,
  get_sampler/0,
  get_propagators/0,
  get_batch_processor_config/0,
  get_otlp_endpoint/0,
  get_otlp_endpoint/1,
  get_log_level/0,
  is_tracing_enabled/0,
  set_tracing_enabled/1,
  is_flight_recorder_enabled/0,
  set_flight_recorder_enabled/1,
  %% Runtime toggles
  is_verbose_tracing/0,
  set_verbose_tracing/1,
  %% Exporter controls
  auto_register_exporters/0,
  auto_register_span_processor/0,
  has_span_processor_config/0,
  enable_exporter/1,
  disable_exporter/1,
  is_exporter_enabled/1,
  get_exporters/0,
  %% SDK version
  get_sdk_version/0,
  %% Span limits (OTel spec defaults: 128 each)
  get_span_attribute_count_limit/0,
  get_span_event_count_limit/0,
  get_span_link_count_limit/0,
  get_span_event_attribute_count_limit/0,
  get_span_link_attribute_count_limit/0,
  get_span_attribute_value_length_limit/0,
  %% Metric cardinality limit (OTel spec recommendation: 2000)
  get_metric_cardinality_limit/0,
  %% OTLP retry settings
  get_otlp_max_retries/0,
  get_otlp_retry_initial_delay_ms/0,
  get_otlp_retry_max_delay_ms/0,
  %% Metrics export interval
  get_metric_export_interval/0,
  %% OTLP headers from OTEL_EXPORTER_OTLP_*HEADERS
  get_otlp_headers/1,
  %% Validated application env
  positive_int_env/2
]).

-define(CONFIG_KEY, '$instrument_config').
-define(TRACING_ENABLED_KEY, '$instrument_tracing_enabled').
-define(FLIGHT_RECORDER_KEY, '$instrument_flight_recorder_enabled').
-define(VERBOSE_TRACING_KEY, '$instrument_verbose_tracing').
-define(DISABLED_EXPORTERS_KEY, '$instrument_disabled_exporters').

%% ============================================================================
%% API
%% ============================================================================

%% @doc Initializes configuration from environment variables.
-spec init() -> ok.
init() ->
  Config = #{
    service_name => read_service_name(),
    service_version => read_service_version(),
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

%% @doc Gets the service version.
-spec get_service_version() -> binary() | undefined.
get_service_version() ->
  get(service_version).

%% @doc Gets resource attributes from application config.
-spec get_resource_config() -> map().
get_resource_config() ->
  application:get_env(instrument, resource, #{}).

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

%% @doc Checks if tracing is globally enabled.
-spec is_tracing_enabled() -> boolean().
is_tracing_enabled() ->
  persistent_term:get(?TRACING_ENABLED_KEY, true).

%% @doc Enables or disables tracing globally.
%% When disabled, span creation is skipped entirely for maximum performance.
-spec set_tracing_enabled(boolean()) -> ok.
set_tracing_enabled(Enabled) when is_boolean(Enabled) ->
  persistent_term:put(?TRACING_ENABLED_KEY, Enabled),
  ok.

%% @doc Checks if the flight recorder is enabled.
%% Note: This reads from instrument_flight_recorder's persistent_term for consistency.
-spec is_flight_recorder_enabled() -> boolean().
is_flight_recorder_enabled() ->
  persistent_term:get(?FLIGHT_RECORDER_KEY, false).

%% @doc Enables or disables the flight recorder.
%% This is a convenience wrapper around instrument_flight_recorder:enable/disable.
-spec set_flight_recorder_enabled(boolean()) -> ok.
set_flight_recorder_enabled(true) ->
  instrument_flight_recorder:enable();
set_flight_recorder_enabled(false) ->
  instrument_flight_recorder:disable().

%% @doc Checks if verbose tracing is enabled.
%% Verbose tracing captures additional attributes but has higher overhead.
%% WARNING: Not recommended for high-throughput production use.
-spec is_verbose_tracing() -> boolean().
is_verbose_tracing() ->
  persistent_term:get(?VERBOSE_TRACING_KEY, false).

%% @doc Enables or disables verbose tracing.
%% When enabled, more detailed attributes are captured.
%% WARNING: Verbose tracing has significant performance overhead.
-spec set_verbose_tracing(boolean()) -> ok.
set_verbose_tracing(Enabled) when is_boolean(Enabled) ->
  persistent_term:put(?VERBOSE_TRACING_KEY, Enabled),
  ok.

%% @doc Auto-registers exporters based on environment variables.
%% Supports standard OTel env vars (OTEL_TRACES_EXPORTER, OTEL_METRICS_EXPORTER,
%% OTEL_LOGS_EXPORTER) and legacy OTEL_EXPORTERS.
%% Supported values: otlp, console, none.
-spec auto_register_exporters() -> ok.
auto_register_exporters() ->
  %% Traces: the first exporter named in OTEL_TRACES_EXPORTER (or
  %% OTEL_EXPORTERS) goes through the batch span processor, registered by
  %% auto_register_span_processor/0. Any further names are registered here
  %% with the span exporter. Nothing is registered here when a span processor
  %% or span exporter is set in the application environment.
  case extra_trace_exporter_names() of
    [] -> ok;
    Extra -> lists:foreach(fun register_exporter_by_name/1, Extra)
  end,
  %% Register metrics exporters (OTEL_METRICS_EXPORTER)
  case os:getenv("OTEL_METRICS_EXPORTER") of
    false -> ok;
    "none" -> ok;
    MetricsValue ->
      MetricsNames = string:tokens(MetricsValue, ","),
      lists:foreach(fun register_metrics_exporter_by_name/1, MetricsNames)
  end,
  %% Register log exporters (OTEL_LOGS_EXPORTER)
  case os:getenv("OTEL_LOGS_EXPORTER") of
    false -> ok;
    "none" -> ok;
    LogsValue ->
      LogsNames = string:tokens(LogsValue, ","),
      lists:foreach(fun register_log_exporter_by_name/1, LogsNames)
  end,
  ok.

%% @doc Auto-registers span processor based on config.
%% Reads from application env {span_processor, {Module, Config}} or
%% uses batch processor with OTEL_BSP_* settings if exporter is available.
-spec auto_register_span_processor() -> ok.
auto_register_span_processor() ->
  case application:get_env(instrument, span_processor) of
    {ok, {Module, Config}} ->
      instrument_span_processor:register(Module, Config);
    _ ->
      %% Any configured trace exporter goes through the batch processor,
      %% tuned by OTEL_BSP_* when set.
      case get_default_exporter() of
        undefined -> ok;
        {ExporterMod, ExporterCfg} ->
          FullConfig = (get_batch_processor_config())#{
            exporter => ExporterMod,
            exporter_config => ExporterCfg
          },
          instrument_span_processor:register(instrument_span_processor_batch, FullConfig)
      end
  end,
  ok.

%% Trace exporter names after the first, when the first comes from the OS env.
extra_trace_exporter_names() ->
  case {application:get_env(instrument, span_processor),
        application:get_env(instrument, span_exporter)} of
    {undefined, undefined} ->
      case os:getenv("OTEL_TRACES_EXPORTER") of
        false -> trace_names(os:getenv("OTEL_EXPORTERS"));
        V -> trace_names(V)
      end;
    _ ->
      []
  end.

trace_names(false) -> [];
trace_names("none") -> [];
trace_names(Value) ->
  case [string:trim(N) || N <- string:tokens(Value, ",")] of
    [_First | Rest] -> Rest;
    [] -> []
  end.

%% @doc Checks if a span processor will be registered at startup.
%% Returns true if the span_processor app config is set, or a trace exporter
%% is configured (it is registered with the batch processor).
-spec has_span_processor_config() -> boolean().
has_span_processor_config() ->
  case application:get_env(instrument, span_processor) of
    {ok, _} -> true;
    _ ->
      get_default_exporter() =/= undefined
  end.

%% @doc Enables a specific exporter.
-spec enable_exporter(module()) -> ok.
enable_exporter(Module) when is_atom(Module) ->
  Disabled = persistent_term:get(?DISABLED_EXPORTERS_KEY, #{}),
  NewDisabled = maps:remove(Module, Disabled),
  persistent_term:put(?DISABLED_EXPORTERS_KEY, NewDisabled),
  ok.

%% @doc Disables a specific exporter.
%% Disabled exporters will not receive spans for export.
-spec disable_exporter(module()) -> ok.
disable_exporter(Module) when is_atom(Module) ->
  Disabled = persistent_term:get(?DISABLED_EXPORTERS_KEY, #{}),
  NewDisabled = maps:put(Module, true, Disabled),
  persistent_term:put(?DISABLED_EXPORTERS_KEY, NewDisabled),
  ok.

%% @doc Checks if an exporter is enabled.
-spec is_exporter_enabled(module()) -> boolean().
is_exporter_enabled(Module) when is_atom(Module) ->
  Disabled = persistent_term:get(?DISABLED_EXPORTERS_KEY, #{}),
  not maps:get(Module, Disabled, false).

%% @doc Gets list of configured exporters from OTEL_EXPORTERS.
-spec get_exporters() -> [atom()].
get_exporters() ->
  case os:getenv("OTEL_EXPORTERS") of
    false -> [];
    Value ->
      Names = string:tokens(Value, ","),
      lists:filtermap(fun parse_exporter_name/1, Names)
  end.

%% @doc Gets the SDK version dynamically from app metadata.
%% Checks instrumentation_scope_version env first, then app vsn, then fallback.
-spec get_sdk_version() -> binary().
get_sdk_version() ->
  case application:get_env(instrument, instrumentation_scope_version) of
    {ok, Version} -> version_to_binary(Version);
    undefined ->
      case application:get_key(instrument, vsn) of
        {ok, Vsn} -> version_to_binary(Vsn);
        undefined -> <<"1.0.0">>
      end
  end.

version_to_binary(V) when is_binary(V) -> V;
version_to_binary(V) when is_list(V) -> instrument_lib:chars_to_binary(V);
version_to_binary(V) when is_atom(V) -> atom_to_binary(V, utf8).

%% @doc Gets the span attribute count limit.
%% Reads from OTEL_SPAN_ATTRIBUTE_COUNT_LIMIT env var, defaults to 128.
-spec get_span_attribute_count_limit() -> pos_integer().
get_span_attribute_count_limit() ->
  read_span_limit("OTEL_SPAN_ATTRIBUTE_COUNT_LIMIT", 128).

%% @doc Gets the span event count limit.
%% Reads from OTEL_SPAN_EVENT_COUNT_LIMIT env var, defaults to 128.
-spec get_span_event_count_limit() -> pos_integer().
get_span_event_count_limit() ->
  read_span_limit("OTEL_SPAN_EVENT_COUNT_LIMIT", 128).

%% @doc Gets the span link count limit.
%% Reads from OTEL_SPAN_LINK_COUNT_LIMIT env var, defaults to 128.
-spec get_span_link_count_limit() -> pos_integer().
get_span_link_count_limit() ->
  read_span_limit("OTEL_SPAN_LINK_COUNT_LIMIT", 128).

%% @doc Gets the per-event attribute count limit.
%% Reads from OTEL_EVENT_ATTRIBUTE_COUNT_LIMIT env var, defaults to 128.
-spec get_span_event_attribute_count_limit() -> pos_integer().
get_span_event_attribute_count_limit() ->
  read_span_limit("OTEL_EVENT_ATTRIBUTE_COUNT_LIMIT", 128).

%% @doc Gets the per-link attribute count limit.
%% Reads from OTEL_LINK_ATTRIBUTE_COUNT_LIMIT env var, defaults to 128.
-spec get_span_link_attribute_count_limit() -> pos_integer().
get_span_link_attribute_count_limit() ->
  read_span_limit("OTEL_LINK_ATTRIBUTE_COUNT_LIMIT", 128).

%% @doc Gets the per-attribute value length limit.
%% Reads from OTEL_ATTRIBUTE_VALUE_LENGTH_LIMIT, returns `unlimited' when
%% unset (the spec default). When set, string and binary attribute values
%% longer than the limit are truncated; list elements are truncated
%% individually.
-spec get_span_attribute_value_length_limit() -> pos_integer() | unlimited.
get_span_attribute_value_length_limit() ->
  case os:getenv("OTEL_ATTRIBUTE_VALUE_LENGTH_LIMIT") of
    false -> unlimited;
    Value ->
      try list_to_integer(Value) of
        Int when is_integer(Int), Int > 0 -> Int;
        _ -> unlimited
      catch _:_ -> unlimited
      end
  end.

%% @doc Gets the per-metric cardinality limit.
%% Reads from OTEL_METRIC_CARDINALITY_LIMIT env var, defaults to 2000.
%% When a vector metric reaches this many distinct label sets, subsequent
%% label sets are aggregated into a single overflow series identified by
%% `otel.metric.overflow=true'.
-spec get_metric_cardinality_limit() -> pos_integer().
get_metric_cardinality_limit() ->
  read_span_limit("OTEL_METRIC_CARDINALITY_LIMIT", 2000).

%% @doc Maximum number of OTLP export attempts per batch.
%% Reads from OTEL_EXPORTER_OTLP_MAX_RETRIES, defaults to 3.
-spec get_otlp_max_retries() -> non_neg_integer().
get_otlp_max_retries() ->
  read_span_limit("OTEL_EXPORTER_OTLP_MAX_RETRIES", 3).

%% @doc Initial delay between OTLP retries in milliseconds.
%% Reads from OTEL_EXPORTER_OTLP_RETRY_INITIAL_DELAY_MS, defaults to 1000.
-spec get_otlp_retry_initial_delay_ms() -> pos_integer().
get_otlp_retry_initial_delay_ms() ->
  read_span_limit("OTEL_EXPORTER_OTLP_RETRY_INITIAL_DELAY_MS", 1000).

%% @doc Maximum delay between OTLP retries in milliseconds.
%% Reads from OTEL_EXPORTER_OTLP_RETRY_MAX_DELAY_MS, defaults to 30000.
-spec get_otlp_retry_max_delay_ms() -> pos_integer().
get_otlp_retry_max_delay_ms() ->
  read_span_limit("OTEL_EXPORTER_OTLP_RETRY_MAX_DELAY_MS", 30000).

%% @doc Metrics export interval in milliseconds.
%% Reads the `metrics_export_interval' application env, then the
%% OTEL_METRIC_EXPORT_INTERVAL env var, and defaults to 60000. A value that is
%% not a positive integer is ignored with a warning.
-spec get_metric_export_interval() -> pos_integer().
get_metric_export_interval() ->
  case application:get_env(instrument, metrics_export_interval) of
    {ok, _} -> positive_int_env(metrics_export_interval, 60000);
    undefined -> read_span_limit("OTEL_METRIC_EXPORT_INTERVAL", 60000)
  end.

%% @doc Reads an `instrument' application env value that must be a positive
%% integer. Returns `Default' when the key is unset, and logs a warning and
%% returns `Default' when the value is invalid.
-spec positive_int_env(atom(), pos_integer()) -> pos_integer().
positive_int_env(Key, Default) ->
  case application:get_env(instrument, Key) of
    undefined -> Default;
    {ok, Int} when is_integer(Int), Int > 0 -> Int;
    {ok, Bad} ->
      logger:warning("instrument: ignoring invalid ~p value ~p, using ~p",
                     [Key, Bad, Default]),
      Default
  end.

%% ============================================================================
%% Internal Functions
%% ============================================================================

read_span_limit(EnvVar, Default) ->
  case os:getenv(EnvVar) of
    false -> Default;
    Value ->
      try list_to_integer(Value) of
        Int when is_integer(Int), Int > 0 -> Int;
        _ -> Default
      catch _:_ -> Default
      end
  end.

read_service_name() ->
  case os:getenv("OTEL_SERVICE_NAME") of
    false -> undefined;
    Value -> instrument_lib:chars_to_binary(Value)
  end.

read_service_version() ->
  case os:getenv("OTEL_SERVICE_VERSION") of
    false -> undefined;
    Value -> instrument_lib:chars_to_binary(Value)
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
parse_propagator("b3") -> {true, instrument_propagator_b3};
parse_propagator("b3multi") -> {true, instrument_propagator_b3_multi};
parse_propagator(_) -> false.

read_batch_processor_config() ->
  Config = #{},
  %% Keys match the batch processor's config keys.
  Config1 = maybe_add_int("OTEL_BSP_SCHEDULE_DELAY", schedule_delay_millis, Config),
  Config2 = maybe_add_int("OTEL_BSP_MAX_QUEUE_SIZE", max_queue_size, Config1),
  Config3 = maybe_add_int("OTEL_BSP_MAX_EXPORT_BATCH_SIZE", max_export_batch_size, Config2),
  maybe_add_int("OTEL_BSP_EXPORT_TIMEOUT", export_timeout_millis, Config3).

%% Adds a positive integer env var to Config; other values are ignored.
maybe_add_int(EnvVar, Key, Config) ->
  case os:getenv(EnvVar) of
    false -> Config;
    Value ->
      try list_to_integer(Value) of
        Int when is_integer(Int), Int > 0 -> maps:put(Key, Int, Config);
        _ -> Config
      catch _:_ -> Config
      end
  end.

read_otlp_endpoint() ->
  case os:getenv("OTEL_EXPORTER_OTLP_ENDPOINT") of
    false -> undefined;
    Value -> instrument_lib:chars_to_binary(Value)
  end.

read_otlp_traces_endpoint() ->
  case os:getenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT") of
    false -> undefined;
    Value -> instrument_lib:chars_to_binary(Value)
  end.

read_otlp_metrics_endpoint() ->
  case os:getenv("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT") of
    false -> undefined;
    Value -> instrument_lib:chars_to_binary(Value)
  end.

read_otlp_logs_endpoint() ->
  case os:getenv("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT") of
    false -> undefined;
    Value -> instrument_lib:chars_to_binary(Value)
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
  try list_to_float(Value) of
    F when is_float(F) -> F
  catch _:_ -> parse_float_as_int(Value, Default)
  end.

parse_float_as_int(Value, Default) ->
  try list_to_integer(Value) of
    I when is_integer(I) -> float(I)
  catch _:_ -> Default
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

register_exporter_by_name("otlp") ->
  case get_otlp_endpoint(traces) of
    undefined -> ok;
    Endpoint ->
      Exporter = instrument_exporter_otlp:new(otlp_config(traces, Endpoint)),
      instrument_exporter:register(Exporter)
  end;
register_exporter_by_name("console") ->
  Exporter = instrument_exporter_console:new(#{}),
  instrument_exporter:register(Exporter);
register_exporter_by_name(_) ->
  ok.

parse_exporter_name("otlp") -> {true, instrument_exporter_otlp};
parse_exporter_name("console") -> {true, instrument_exporter_console};
parse_exporter_name(_) -> false.

register_metrics_exporter_by_name(Name) ->
  case parse_metrics_exporter_name(string:trim(Name)) of
    {true, Module} ->
      Config = case Module of
        instrument_metrics_exporter_otlp ->
          case get_otlp_endpoint(metrics) of
            undefined -> #{};
            Endpoint -> otlp_config(metrics, Endpoint)
          end;
        _ -> #{}
      end,
      Exporter = Module:new(Config),
      instrument_metrics_exporter:register(Exporter);
    false -> ok
  end.

parse_metrics_exporter_name("otlp") -> {true, instrument_metrics_exporter_otlp};
parse_metrics_exporter_name("console") -> {true, instrument_metrics_exporter_console};
parse_metrics_exporter_name(_) -> false.

register_log_exporter_by_name(Name) ->
  case parse_log_exporter_name(string:trim(Name)) of
    {true, Module} ->
      Config = case Module of
        instrument_log_exporter_otlp ->
          case get_otlp_endpoint(logs) of
            undefined -> #{};
            Endpoint -> otlp_config(logs, Endpoint)
          end;
        _ -> #{}
      end,
      Exporter = Module:new(Config),
      instrument_log_exporter:register(Exporter);
    false -> ok
  end.

parse_log_exporter_name("otlp") -> {true, instrument_log_exporter_otlp};
parse_log_exporter_name("console") -> {true, instrument_log_exporter_console};
parse_log_exporter_name(_) -> false.

%% Exporter config for an endpoint, with headers from
%% OTEL_EXPORTER_OTLP_<SIGNAL>_HEADERS or OTEL_EXPORTER_OTLP_HEADERS.
otlp_config(Signal, Endpoint) ->
  case get_otlp_headers(Signal) of
    Headers when map_size(Headers) =:= 0 -> #{endpoint => Endpoint};
    Headers -> #{endpoint => Endpoint, headers => Headers}
  end.

%% @doc OTLP request headers for a signal, from
%% OTEL_EXPORTER_OTLP_TRACES_HEADERS (or _METRICS_, _LOGS_) when set, else
%% OTEL_EXPORTER_OTLP_HEADERS. The format is `key1=value1,key2=value2' with
%% percent-encoded values, as in the OpenTelemetry specification. Malformed
%% entries are skipped.
-spec get_otlp_headers(traces | metrics | logs) -> #{binary() => binary()}.
get_otlp_headers(Signal) ->
  Specific = "OTEL_EXPORTER_OTLP_" ++ string:uppercase(atom_to_list(Signal)) ++ "_HEADERS",
  case os:getenv(Specific) of
    false ->
      case os:getenv("OTEL_EXPORTER_OTLP_HEADERS") of
        false -> #{};
        Value -> parse_otlp_headers(Value)
      end;
    Value ->
      parse_otlp_headers(Value)
  end.

percent_decoded(S) ->
  case uri_string:percent_decode(S) of
    D when is_list(D); is_binary(D) -> instrument_lib:chars_to_binary(D);
    _ -> erlang:error(badarg)
  end.

parse_otlp_headers(Value) ->
  maps:from_list(lists:filtermap(fun(Entry) ->
    case string:split(Entry, "=") of
      [K, V] ->
        Key = string:trim(K),
        case Key of
          "" -> false;
          _ ->
            try
              {true, {percent_decoded(Key), percent_decoded(string:trim(V))}}
            catch _:_ -> false
            end
        end;
      _ ->
        false
    end
  end, string:tokens(Value, ","))).

get_default_exporter() ->
  %% First check application env
  case application:get_env(instrument, span_exporter) of
    {ok, {Module, Config}} -> {Module, Config};
    _ ->
      %% Check OTEL_TRACES_EXPORTER first, then fall back to OTEL_EXPORTERS
      ExporterEnv = case os:getenv("OTEL_TRACES_EXPORTER") of
        false -> os:getenv("OTEL_EXPORTERS");
        V -> V
      end,
      case ExporterEnv of
        false -> undefined;
        "none" -> undefined;
        Value ->
          case string:tokens(Value, ",") of
            ["otlp" | _] ->
              case get_otlp_endpoint(traces) of
                undefined -> undefined;
                Endpoint -> {instrument_exporter_otlp, otlp_config(traces, Endpoint)}
              end;
            ["console" | _] ->
              {instrument_exporter_console, #{}};
            _ -> undefined
          end
      end
  end.
