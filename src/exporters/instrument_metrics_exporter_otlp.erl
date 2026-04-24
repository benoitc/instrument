%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc OTLP HTTP exporter for metrics.
%%
%% Exports metrics to an OpenTelemetry Collector or compatible backend
%% using the OTLP/HTTP protocol with JSON encoding.
%%
%% == Example Usage ==
%% ```
%% %% Export to local collector
%% instrument_metrics_exporter:register(instrument_metrics_exporter_otlp:new(#{
%%     endpoint => "http://localhost:4318"
%% })),
%%
%% %% Export to remote collector with authentication
%% instrument_metrics_exporter:register(instrument_metrics_exporter_otlp:new(#{
%%     endpoint => "https://otel-collector.example.com:4318",
%%     headers => #{
%%         <<"Authorization">> => <<"Bearer token123">>
%%     },
%%     compression => gzip
%% })),
%% '''
%%
%% == Configuration Options ==
%% <ul>
%%   <li>`endpoint' - Base URL of the OTLP receiver (required)</li>
%%   <li>`headers' - Additional HTTP headers (default: #{})</li>
%%   <li>`compression' - Compression: none | gzip (default: none)</li>
%%   <li>`timeout' - Request timeout in ms (default: 10000)</li>
%% </ul>
-module(instrument_metrics_exporter_otlp).
-author("benoitc").

%% Public API
-export([new/1]).

%% Exporter callbacks
-export([exporter_init/1, exporter_export/2, exporter_shutdown/1]).

-include("instrument_otel.hrl").

-record(state, {
  endpoint :: binary(),
  metrics_path :: binary(),
  headers :: [{binary(), binary()}],
  compression :: none | gzip,
  timeout :: pos_integer()
}).

-define(DEFAULT_METRICS_PATH, <<"/v1/metrics">>).
-define(DEFAULT_TIMEOUT, 10000).

%% ============================================================================
%% Public API
%% ============================================================================

%% @doc Creates a new OTLP exporter configuration.
-spec new(map()) -> #{module := module(), config := map()}.
new(Config) when is_map(Config) ->
  #{module => ?MODULE, config => Config}.

%% ============================================================================
%% Exporter callbacks
%% ============================================================================

%% @doc Initializes the exporter.
-spec exporter_init(map()) -> {ok, #state{}} | {error, term()}.
exporter_init(Config) ->
  case maps:get(endpoint, Config, undefined) of
    undefined ->
      {error, missing_endpoint};
    Endpoint ->
      EndpointBin = to_binary(Endpoint),
      DefaultPath = ?DEFAULT_METRICS_PATH,
      MetricsPath = maps:get(metrics_path, Config, DefaultPath),
      %% Check if endpoint already contains the signal path (per-signal endpoint)
      {NormalizedEndpoint, EffectivePath} = normalize_endpoint(EndpointBin, MetricsPath),
      Headers = maps:to_list(maps:get(headers, Config, #{})),
      Compression = maps:get(compression, Config, none),
      Timeout = maps:get(timeout, Config, ?DEFAULT_TIMEOUT),

      {ok, #state{
        endpoint = NormalizedEndpoint,
        metrics_path = EffectivePath,
        headers = Headers,
        compression = Compression,
        timeout = Timeout
      }}
  end.

%% @doc Exports metrics to the OTLP endpoint.
-spec exporter_export([map()], #state{}) ->
  {ok, #state{}}
  | {error, retryable, #state{}}
  | {error, permanent, #state{}}.
exporter_export([], State) ->
  {ok, State};
exporter_export(Metrics, #state{} = State) ->
  Payload = encode_metrics(Metrics),
  case send_request(Payload, State) of
    ok ->
      {ok, State};
    {error, Kind, _Reason} when Kind =:= retryable; Kind =:= permanent ->
      {error, Kind, State}
  end.

%% @doc Shuts down the exporter.
-spec exporter_shutdown(#state{}) -> ok.
exporter_shutdown(_State) ->
  ok.

%% ============================================================================
%% Internal functions
%% ============================================================================

encode_metrics(Metrics) ->
  ResourceMetrics = group_metrics(Metrics),
  Payload = #{<<"resourceMetrics">> => ResourceMetrics},
  json:encode(Payload).

group_metrics(Metrics) ->
  ScopeMetrics = group_by_scope(Metrics),
  [#{
    <<"resource">> => #{
      <<"attributes">> => encode_resource_attributes()
    },
    <<"scopeMetrics">> => ScopeMetrics
  }].

group_by_scope(Metrics) ->
  %% Group metrics by their meter's instrumentation scope
  Grouped = lists:foldl(fun(Metric, Acc) ->
    Key = get_meter_scope_key(Metric),
    maps:update_with(Key, fun(L) -> [Metric|L] end, [Metric], Acc)
  end, #{}, Metrics),
  [encode_scope_metrics_grouped(K, lists:reverse(V)) || {K, V} <- maps:to_list(Grouped)].

get_meter_scope_key(#{name := Name}) ->
  case instrument_meter:get_instrument(Name) of
    #otel_instrument{meter = #meter{name = N, version = V, schema_url = S}} ->
      {N, meter_version_to_binary(V, <<>>), S};
    _ ->
      %% Fallback to default scope
      {<<"instrument">>, instrument_config:get_sdk_version(), undefined}
  end;
get_meter_scope_key(_) ->
  {<<"instrument">>, instrument_config:get_sdk_version(), undefined}.

encode_scope_metrics_grouped({Name, Version, SchemaUrl}, Metrics) ->
  Scope = #{<<"name">> => Name, <<"version">> => Version},
  Scope2 = maybe_add_schema_url(Scope, SchemaUrl),
  #{<<"scope">> => Scope2, <<"metrics">> => [encode_metric(M) || M <- Metrics]}.

maybe_add_schema_url(Scope, undefined) -> Scope;
maybe_add_schema_url(Scope, SchemaUrl) -> Scope#{<<"schemaUrl">> => SchemaUrl}.

meter_version_to_binary(undefined, Default) -> Default;
meter_version_to_binary(V, _Default) when is_binary(V) -> V.

encode_resource_attributes() ->
  Resource = instrument_resource:get_default(),
  Attrs = instrument_resource:get_attributes(Resource),
  maps:fold(fun(K, V, Acc) ->
    [#{<<"key">> => to_binary(K), <<"value">> => encode_attr_value(V)} | Acc]
  end, [], Attrs).

encode_metric(#{name := Name, type := Type, data_points := DataPoints} = Metric) ->
  Description = maps:get(description, Metric, <<>>),
  Unit = maps:get(unit, Metric, <<"1">>),
  %% Look up instrument to get temporality
  Temporality = get_instrument_temporality(Name),
  Base = #{
    <<"name">> => Name,
    <<"description">> => Description,
    <<"unit">> => Unit
  },
  maps:merge(Base, encode_metric_data(Type, DataPoints, Temporality)).

encode_metric_data(counter, DataPoints, Temporality) ->
  #{
    <<"sum">> => #{
      <<"dataPoints">> => [encode_number_data_point(DP) || DP <- DataPoints],
      <<"aggregationTemporality">> => temporality_to_int(Temporality),
      <<"isMonotonic">> => true
    }
  };

encode_metric_data(gauge, DataPoints, _Temporality) ->
  #{
    <<"gauge">> => #{
      <<"dataPoints">> => [encode_number_data_point(DP) || DP <- DataPoints]
    }
  };

encode_metric_data(histogram, DataPoints, Temporality) ->
  #{
    <<"histogram">> => #{
      <<"dataPoints">> => [encode_histogram_data_point(DP) || DP <- DataPoints],
      <<"aggregationTemporality">> => temporality_to_int(Temporality)
    }
  }.

%% Get instrument temporality, defaulting to cumulative
get_instrument_temporality(Name) ->
  case instrument_meter:get_instrument(Name) of
    #otel_instrument{temporality = Temporality} -> Temporality;
    _ -> cumulative
  end.

%% Convert temporality atom to OTLP integer
temporality_to_int(delta) -> 1;       %% DELTA
temporality_to_int(cumulative) -> 2.  %% CUMULATIVE

encode_number_data_point(#{attributes := Attrs, value := Value, timestamp := Ts} = DP) ->
  ValueField = case is_integer(Value) of
    true -> #{<<"asInt">> => integer_to_binary(Value)};
    false -> #{<<"asDouble">> => Value}
  end,
  Base = #{
    <<"attributes">> => encode_attributes(Attrs),
    <<"timeUnixNano">> => integer_to_binary(Ts)
  },
  %% Add startTimeUnixNano for cumulative metrics (counters)
  Base2 = case maps:get(start_time, DP, undefined) of
    undefined -> Base;
    StartTime -> Base#{<<"startTimeUnixNano">> => integer_to_binary(StartTime)}
  end,
  maps:merge(Base2, ValueField).

encode_histogram_data_point(#{attributes := Attrs, value := Value, timestamp := Ts} = DP) ->
  #{count := Count, sum := Sum, buckets := Buckets} = Value,
  %% OTLP bucketCounts must be one longer than explicitBounds (includes +Inf bucket)
  %% Get individual bucket counts (not cumulative)
  BucketCounts = [maps:get(count, B, 0) || B <- Buckets],
  %% ExplicitBounds excludes +Inf
  ExplicitBounds = [maps:get(upper_bound, B) || B <- Buckets,
                    maps:get(upper_bound, B) =/= infinity],
  Exemplars = maps:get(exemplars, Value, []),
  Base = #{
    <<"attributes">> => encode_attributes(Attrs),
    <<"timeUnixNano">> => integer_to_binary(Ts),
    <<"count">> => encode_uint64(Count),
    <<"sum">> => Sum,
    <<"bucketCounts">> => [encode_uint64(C) || C <- BucketCounts],
    <<"explicitBounds">> => ExplicitBounds,
    <<"exemplars">> => [encode_exemplar(E) || E <- Exemplars]
  },
  %% Add startTimeUnixNano for cumulative histograms
  case maps:get(start_time, DP, undefined) of
    undefined -> Base;
    StartTime -> Base#{<<"startTimeUnixNano">> => integer_to_binary(StartTime)}
  end.

%% Encode count as string (OTLP uses fixed64/string for counts)
encode_uint64(V) when is_integer(V) -> integer_to_binary(V);
encode_uint64(V) when is_float(V) -> integer_to_binary(trunc(V)).

-include("instrument_otel.hrl").

%% Encode an exemplar record to OTLP format
encode_exemplar(#exemplar{
  filtered_attributes = FilteredAttrs,
  value = Value,
  timestamp = Timestamp,
  span_id = SpanId,
  trace_id = TraceId
}) ->
  ValueField = case is_integer(Value) of
    true -> #{<<"asInt">> => integer_to_binary(Value)};
    false -> #{<<"asDouble">> => Value}
  end,
  Base = #{
    <<"filteredAttributes">> => encode_attributes(FilteredAttrs),
    <<"timeUnixNano">> => integer_to_binary(Timestamp)
  },
  Base2 = maps:merge(Base, ValueField),
  %% Add trace context if available
  Base3 = case SpanId of
    undefined -> Base2;
    _ -> Base2#{<<"spanId">> => binary:encode_hex(SpanId, lowercase)}
  end,
  case TraceId of
    undefined -> Base3;
    _ -> Base3#{<<"traceId">> => binary:encode_hex(TraceId, lowercase)}
  end;
encode_exemplar(_) ->
  #{}.

encode_attributes(Attrs) ->
  maps:fold(fun(K, V, Acc) ->
    [encode_attribute(K, V) | Acc]
  end, [], Attrs).

encode_attribute(Key, Value) ->
  #{
    <<"key">> => to_binary(Key),
    <<"value">> => encode_attr_value(Value)
  }.

encode_attr_value(V) when is_binary(V) ->
  #{<<"stringValue">> => V};
encode_attr_value(V) when is_atom(V) ->
  #{<<"stringValue">> => atom_to_binary(V, utf8)};
encode_attr_value(V) when is_integer(V) ->
  #{<<"intValue">> => integer_to_binary(V)};
encode_attr_value(V) when is_float(V) ->
  #{<<"doubleValue">> => V};
encode_attr_value(true) ->
  #{<<"boolValue">> => true};
encode_attr_value(false) ->
  #{<<"boolValue">> => false};
encode_attr_value(V) when is_list(V) ->
  #{<<"arrayValue">> => #{<<"values">> => [encode_attr_value(E) || E <- V]}};
encode_attr_value(V) ->
  #{<<"stringValue">> => iolist_to_binary(io_lib:format("~p", [V]))}.

send_request(Payload, #state{
  endpoint = Endpoint,
  metrics_path = MetricsPath,
  headers = ExtraHeaders,
  compression = Compression,
  timeout = Timeout
}) ->
  Url = <<Endpoint/binary, MetricsPath/binary>>,

  {Body, ContentEncoding} = case Compression of
    gzip ->
      {zlib:gzip(Payload), [{<<"content-encoding">>, <<"gzip">>}]};
    none ->
      {Payload, []}
  end,

  Headers = [
    {<<"content-type">>, <<"application/json">>}
    | ContentEncoding
  ] ++ ExtraHeaders,

  Options = [
    {recv_timeout, Timeout},
    {connect_timeout, Timeout}
  ],

  instrument_otlp_retry:send_with_retry(post, Url, Headers, Body, Options).

to_binary(V) when is_binary(V) -> V;
to_binary(V) when is_list(V) -> list_to_binary(V);
to_binary(V) when is_atom(V) -> atom_to_binary(V, utf8).

%% @private
%% Normalize endpoint URL and determine effective path.
normalize_endpoint(Endpoint, SignalPath) ->
  StrippedEndpoint = case binary:last(Endpoint) of
    $/ -> binary:part(Endpoint, 0, byte_size(Endpoint) - 1);
    _ -> Endpoint
  end,
  PathLen = byte_size(SignalPath),
  EndpointLen = byte_size(StrippedEndpoint),
  case EndpointLen >= PathLen of
    true ->
      Suffix = binary:part(StrippedEndpoint, EndpointLen - PathLen, PathLen),
      case Suffix of
        SignalPath -> {StrippedEndpoint, <<>>};
        _ -> {StrippedEndpoint, SignalPath}
      end;
    false ->
      {StrippedEndpoint, SignalPath}
  end.
