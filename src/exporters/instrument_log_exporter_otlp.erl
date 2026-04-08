%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc OTLP HTTP exporter for log records.
%%
%% Exports log records to an OpenTelemetry Collector or compatible backend
%% using the OTLP/HTTP protocol with JSON encoding.
%%
%% == Example Usage ==
%% ```
%% %% Export to local collector
%% instrument_log_exporter:register(instrument_log_exporter_otlp:new(#{
%%     endpoint => "http://localhost:4318"
%% })).
%%
%% %% Export to remote collector with authentication
%% instrument_log_exporter:register(instrument_log_exporter_otlp:new(#{
%%     endpoint => "https://collector.example.com:4318",
%%     headers => #{
%%         <<"Authorization">> => <<"Bearer token123">>
%%     },
%%     compression => gzip
%% })).
%% '''
%%
%% == Configuration Options ==
%%
%% `endpoint' - Base URL of the OTLP receiver (required)
%%
%% `headers' - Additional HTTP headers (default: #{})
%%
%% `compression' - Compression: none | gzip (default: none)
%%
%% `timeout' - Request timeout in ms (default: 10000)
%%
%% `logs_path' - API path (default: "/v1/logs")
-module(instrument_log_exporter_otlp).
-author("benoitc").

%% Public API
-export([new/1]).

%% Exporter callbacks
-export([exporter_init/1, exporter_export/2, exporter_shutdown/1, exporter_force_flush/1]).

-include("instrument_otel.hrl").

-record(state, {
  endpoint :: binary(),
  logs_path :: binary(),
  headers :: [{binary(), binary()}],
  compression :: none | gzip,
  timeout :: pos_integer()
}).

-define(DEFAULT_LOGS_PATH, <<"/v1/logs">>).
-define(DEFAULT_TIMEOUT, 10000).

%% ============================================================================
%% Public API
%% ============================================================================

%% @doc Creates a new OTLP log exporter configuration.
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
      DefaultPath = ?DEFAULT_LOGS_PATH,
      LogsPath = maps:get(logs_path, Config, DefaultPath),
      %% Check if endpoint already contains the signal path (per-signal endpoint)
      {NormalizedEndpoint, EffectivePath} = normalize_endpoint(EndpointBin, LogsPath),
      Headers = maps:to_list(maps:get(headers, Config, #{})),
      Compression = maps:get(compression, Config, none),
      Timeout = maps:get(timeout, Config, ?DEFAULT_TIMEOUT),

      {ok, #state{
        endpoint = NormalizedEndpoint,
        logs_path = EffectivePath,
        headers = Headers,
        compression = Compression,
        timeout = Timeout
      }}
  end.

%% @doc Exports log records to the OTLP endpoint.
-spec exporter_export([#log_record{}], #state{}) -> {ok, #state{}} | {error, term(), #state{}}.
exporter_export([], State) ->
  {ok, State};
exporter_export(LogRecords, #state{} = State) ->
  Payload = encode_log_records(LogRecords),
  case send_request(Payload, State) of
    ok ->
      {ok, State};
    {error, Reason} ->
      {error, Reason, State}
  end.

%% @doc Shuts down the exporter.
-spec exporter_shutdown(#state{}) -> ok.
exporter_shutdown(_State) ->
  ok.

%% @doc Forces a flush (handled by exporter manager).
-spec exporter_force_flush(#state{}) -> {ok, #state{}}.
exporter_force_flush(State) ->
  {ok, State}.

%% ============================================================================
%% Internal functions
%% ============================================================================

encode_log_records(LogRecords) ->
  %% Group logs by resource and scope
  ResourceLogs = group_logs(LogRecords),
  Payload = #{<<"resourceLogs">> => ResourceLogs},
  json:encode(Payload).

group_logs(LogRecords) ->
  %% For simplicity, group all logs under a single resource
  ScopeLogs = group_by_scope(LogRecords),
  [#{
    <<"resource">> => #{
      <<"attributes">> => encode_resource_attributes()
    },
    <<"scopeLogs">> => ScopeLogs
  }].

encode_resource_attributes() ->
  Resource = instrument_resource:get_default(),
  Attrs = instrument_resource:get_attributes(Resource),
  maps:fold(fun(K, V, Acc) ->
    [#{<<"key">> => to_binary(K), <<"value">> => encode_attr_value(V)} | Acc]
  end, [], Attrs).

group_by_scope(LogRecords) ->
  %% Group logs by their scope
  Grouped = lists:foldl(fun(#log_record{scope = S} = L, Acc) ->
    Key = log_scope_key(S),
    maps:update_with(Key, fun(Ls) -> [L|Ls] end, [L], Acc)
  end, #{}, LogRecords),
  [encode_scope_logs(K, lists:reverse(V)) || {K, V} <- maps:to_list(Grouped)].

log_scope_key(undefined) ->
  {<<"instrument">>, instrument_config:get_sdk_version(), undefined};
log_scope_key(#scope{name = N, version = V, schema_url = S}) ->
  {N, scope_version_to_binary(V, <<>>), S}.

encode_scope_logs({Name, Version, SchemaUrl}, Logs) ->
  Scope = #{<<"name">> => Name, <<"version">> => Version},
  Scope2 = maybe_add_schema_url(Scope, SchemaUrl),
  #{<<"scope">> => Scope2, <<"logRecords">> => [encode_log_record(L) || L <- Logs]}.

maybe_add_schema_url(Scope, undefined) -> Scope;
maybe_add_schema_url(Scope, SchemaUrl) -> Scope#{<<"schemaUrl">> => SchemaUrl}.

scope_version_to_binary(undefined, Default) -> Default;
scope_version_to_binary(V, _Default) when is_binary(V) -> V.

encode_log_record(#log_record{
  timestamp = Timestamp,
  observed_timestamp = ObservedTimestamp,
  severity_number = SeverityNumber,
  severity_text = SeverityText,
  body = Body,
  attributes = Attributes,
  trace_id = TraceId,
  span_id = SpanId,
  trace_flags = TraceFlags
}) ->
  LogMap = #{
    <<"timeUnixNano">> => integer_to_binary(ensure_timestamp(Timestamp)),
    <<"observedTimeUnixNano">> => integer_to_binary(ensure_timestamp(ObservedTimestamp)),
    <<"severityNumber">> => ensure_integer(SeverityNumber, 9),
    <<"severityText">> => ensure_binary(SeverityText, <<"INFO">>),
    <<"body">> => encode_body(Body),
    <<"attributes">> => encode_attributes(Attributes)
  },
  add_trace_context(LogMap, TraceId, SpanId, TraceFlags).

ensure_timestamp(Ts) when is_integer(Ts) ->
  Ts;
ensure_timestamp(_) ->
  erlang:system_time(nanosecond).

ensure_integer(undefined, Default) -> Default;
ensure_integer(N, _) when is_integer(N) -> N.

ensure_binary(undefined, Default) -> Default;
ensure_binary(B, _) when is_binary(B) -> B.

encode_body(Body) when is_binary(Body) ->
  #{<<"stringValue">> => Body};
encode_body(Body) when is_list(Body) ->
  #{<<"stringValue">> => iolist_to_binary(Body)};
encode_body({Format, Args}) when is_list(Format) ->
  #{<<"stringValue">> => iolist_to_binary(io_lib:format(Format, Args))};
encode_body({report, Report}) ->
  #{<<"stringValue">> => iolist_to_binary(io_lib:format("~p", [Report]))};
encode_body({string, String}) ->
  #{<<"stringValue">> => iolist_to_binary(String)};
encode_body(Body) ->
  #{<<"stringValue">> => iolist_to_binary(io_lib:format("~p", [Body]))}.

add_trace_context(Map, undefined, _, _) ->
  Map;
add_trace_context(Map, TraceId, SpanId, TraceFlags) ->
  Map2 = Map#{<<"traceId">> => encode_trace_id(TraceId)},
  Map3 = case SpanId of
    undefined -> Map2;
    _ -> Map2#{<<"spanId">> => encode_span_id(SpanId)}
  end,
  case TraceFlags of
    undefined -> Map3;
    _ -> Map3#{<<"flags">> => TraceFlags}
  end.

encode_trace_id(TraceId) when is_binary(TraceId), byte_size(TraceId) =:= 16 ->
  %% Encode as lowercase hex per OTLP spec
  binary:encode_hex(TraceId, lowercase);
encode_trace_id(TraceId) when is_binary(TraceId) ->
  %% Already encoded (hex), return as-is
  TraceId.

encode_span_id(SpanId) when is_binary(SpanId), byte_size(SpanId) =:= 8 ->
  %% Encode as lowercase hex per OTLP spec
  binary:encode_hex(SpanId, lowercase);
encode_span_id(SpanId) when is_binary(SpanId) ->
  SpanId.

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
  logs_path = LogsPath,
  headers = ExtraHeaders,
  compression = Compression,
  timeout = Timeout
}) ->
  Url = <<Endpoint/binary, LogsPath/binary>>,

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
