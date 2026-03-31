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
-export([init/1, export/2, shutdown/1, force_flush/1]).

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
-spec init(map()) -> {ok, #state{}} | {error, term()}.
init(Config) ->
  case maps:get(endpoint, Config, undefined) of
    undefined ->
      {error, missing_endpoint};
    Endpoint ->
      EndpointBin = to_binary(Endpoint),
      MetricsPath = maps:get(metrics_path, Config, ?DEFAULT_METRICS_PATH),
      Headers = maps:to_list(maps:get(headers, Config, #{})),
      Compression = maps:get(compression, Config, none),
      Timeout = maps:get(timeout, Config, ?DEFAULT_TIMEOUT),

      {ok, #state{
        endpoint = EndpointBin,
        metrics_path = MetricsPath,
        headers = Headers,
        compression = Compression,
        timeout = Timeout
      }}
  end.

%% @doc Exports metrics to the OTLP endpoint.
-spec export([map()], #state{}) -> {ok, #state{}} | {error, term(), #state{}}.
export([], State) ->
  {ok, State};
export(Metrics, #state{} = State) ->
  Payload = encode_metrics(Metrics),
  case send_request(Payload, State) of
    ok ->
      {ok, State};
    {error, Reason} ->
      {error, Reason, State}
  end.

%% @doc Shuts down the exporter.
-spec shutdown(#state{}) -> ok.
shutdown(_State) ->
  ok.

%% @doc Forces a flush (handled by exporter manager).
-spec force_flush(#state{}) -> {ok, #state{}}.
force_flush(State) ->
  {ok, State}.

%% ============================================================================
%% Internal functions
%% ============================================================================

encode_metrics(Metrics) ->
  ResourceMetrics = group_metrics(Metrics),
  Payload = #{<<"resourceMetrics">> => ResourceMetrics},
  json:encode(Payload).

group_metrics(Metrics) ->
  ScopeMetrics = [encode_scope_metrics(Metrics)],
  [#{
    <<"resource">> => #{
      <<"attributes">> => encode_resource_attributes()
    },
    <<"scopeMetrics">> => ScopeMetrics
  }].

encode_resource_attributes() ->
  Resource = instrument_resource:get_default(),
  Attrs = instrument_resource:get_attributes(Resource),
  maps:fold(fun(K, V, Acc) ->
    [#{<<"key">> => to_binary(K), <<"value">> => encode_attr_value(V)} | Acc]
  end, [], Attrs).

encode_scope_metrics(Metrics) ->
  #{
    <<"scope">> => #{
      <<"name">> => <<"instrument">>,
      <<"version">> => <<"0.3.0">>
    },
    <<"metrics">> => [encode_metric(M) || M <- Metrics]
  }.

encode_metric(#{name := Name, type := Type, data_points := DataPoints} = Metric) ->
  Description = maps:get(description, Metric, <<>>),
  Unit = maps:get(unit, Metric, <<"1">>),
  Base = #{
    <<"name">> => Name,
    <<"description">> => Description,
    <<"unit">> => Unit
  },
  maps:merge(Base, encode_metric_data(Type, DataPoints)).

encode_metric_data(counter, DataPoints) ->
  #{
    <<"sum">> => #{
      <<"dataPoints">> => [encode_number_data_point(DP) || DP <- DataPoints],
      <<"aggregationTemporality">> => 2,  %% CUMULATIVE
      <<"isMonotonic">> => true
    }
  };

encode_metric_data(gauge, DataPoints) ->
  #{
    <<"gauge">> => #{
      <<"dataPoints">> => [encode_number_data_point(DP) || DP <- DataPoints]
    }
  };

encode_metric_data(histogram, DataPoints) ->
  #{
    <<"histogram">> => #{
      <<"dataPoints">> => [encode_histogram_data_point(DP) || DP <- DataPoints],
      <<"aggregationTemporality">> => 2  %% CUMULATIVE
    }
  }.

encode_number_data_point(#{attributes := Attrs, value := Value, timestamp := Ts}) ->
  ValueField = case is_integer(Value) of
    true -> #{<<"asInt">> => integer_to_binary(Value)};
    false -> #{<<"asDouble">> => Value}
  end,
  maps:merge(#{
    <<"attributes">> => encode_attributes(Attrs),
    <<"timeUnixNano">> => integer_to_binary(Ts)
  }, ValueField).

encode_histogram_data_point(#{attributes := Attrs, value := Value, timestamp := Ts}) ->
  #{count := Count, sum := Sum, buckets := Buckets} = Value,
  BucketCounts = [maps:get(count, B) || B <- Buckets],
  ExplicitBounds = [maps:get(bound, B) || B <- Buckets, maps:get(bound, B) =/= infinity],
  #{
    <<"attributes">> => encode_attributes(Attrs),
    <<"timeUnixNano">> => integer_to_binary(Ts),
    <<"count">> => integer_to_binary(Count),
    <<"sum">> => Sum,
    <<"bucketCounts">> => [integer_to_binary(C) || C <- BucketCounts],
    <<"explicitBounds">> => ExplicitBounds
  }.

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

  case hackney:request(post, Url, Headers, Body, Options) of
    {ok, StatusCode, _RespHeaders, _RespBody} when StatusCode >= 200, StatusCode < 300 ->
      ok;
    {ok, StatusCode, _RespHeaders, ResponseBody} ->
      {error, {http_error, StatusCode, ResponseBody}};
    {error, Reason} ->
      {error, Reason}
  end.

to_binary(V) when is_binary(V) -> V;
to_binary(V) when is_list(V) -> list_to_binary(V);
to_binary(V) when is_atom(V) -> atom_to_binary(V, utf8).
