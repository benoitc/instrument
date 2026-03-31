%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc OTLP HTTP exporter for spans.
%%
%% Exports spans to an OpenTelemetry Collector or compatible backend
%% using the OTLP/HTTP protocol with JSON encoding.
%%
%% == Example Usage ==
%% ```
%% %% Export to local collector
%% instrument_exporter:register(instrument_exporter_otlp:new(#{
%%     endpoint => "http://localhost:4318"
%% })),
%%
%% %% Export to remote collector with authentication
%% instrument_exporter:register(instrument_exporter_otlp:new(#{
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
-module(instrument_exporter_otlp).
-author("benoitc").

%% Public API
-export([new/1]).

%% Exporter callbacks
-export([init/1, export/2, shutdown/1, force_flush/1]).

-include("instrument_otel.hrl").

-record(state, {
  endpoint :: binary(),
  traces_path :: binary(),
  headers :: [{binary(), binary()}],
  compression :: none | gzip,
  timeout :: pos_integer()
}).

-define(DEFAULT_TRACES_PATH, <<"/v1/traces">>).
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
      TracesPath = maps:get(traces_path, Config, ?DEFAULT_TRACES_PATH),
      Headers = maps:to_list(maps:get(headers, Config, #{})),
      Compression = maps:get(compression, Config, none),
      Timeout = maps:get(timeout, Config, ?DEFAULT_TIMEOUT),

      {ok, #state{
        endpoint = EndpointBin,
        traces_path = TracesPath,
        headers = Headers,
        compression = Compression,
        timeout = Timeout
      }}
  end.

%% @doc Exports spans to the OTLP endpoint.
-spec export([#span{}], #state{}) -> {ok, #state{}} | {error, term(), #state{}}.
export([], State) ->
  {ok, State};
export(Spans, #state{} = State) ->
  Payload = encode_spans(Spans),
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

encode_spans(Spans) ->
  %% Group spans by resource and scope
  ResourceSpans = group_spans(Spans),
  Payload = #{<<"resourceSpans">> => ResourceSpans},
  json:encode(Payload).

group_spans(Spans) ->
  %% For simplicity, group all spans under a single resource
  %% In a full implementation, you'd group by actual resource attributes
  ScopeSpans = group_by_scope(Spans),
  [#{
    <<"resource">> => #{
      <<"attributes">> => encode_resource_attributes()
    },
    <<"scopeSpans">> => ScopeSpans
  }].

encode_resource_attributes() ->
  Resource = instrument_resource:get_default(),
  Attrs = instrument_resource:get_attributes(Resource),
  maps:fold(fun(K, V, Acc) ->
    [#{<<"key">> => to_binary(K), <<"value">> => encode_attr_value(V)} | Acc]
  end, [], Attrs).

group_by_scope(Spans) ->
  %% For simplicity, put all spans in a single scope
  [#{
    <<"scope">> => #{
      <<"name">> => <<"instrument">>,
      <<"version">> => <<"0.3.0">>
    },
    <<"spans">> => [encode_span(S) || S <- Spans]
  }].

encode_span(#span{
  name = Name,
  ctx = #span_ctx{trace_id = TraceId, span_id = SpanId, trace_flags = TraceFlags},
  parent_ctx = ParentCtx,
  kind = Kind,
  start_time = StartTime,
  end_time = EndTime,
  attributes = Attributes,
  events = Events,
  links = Links,
  status = Status
}) ->
  ParentSpanId = case ParentCtx of
    #span_ctx{span_id = PSpanId} -> base64:encode(PSpanId);
    undefined -> <<>>
  end,

  EndTimeNano = case EndTime of
    undefined -> erlang:monotonic_time(nanosecond);
    _ -> EndTime
  end,

  #{
    <<"traceId">> => base64:encode(TraceId),
    <<"spanId">> => base64:encode(SpanId),
    <<"parentSpanId">> => ParentSpanId,
    <<"name">> => Name,
    <<"kind">> => encode_span_kind(Kind),
    <<"startTimeUnixNano">> => integer_to_binary(StartTime),
    <<"endTimeUnixNano">> => integer_to_binary(EndTimeNano),
    <<"traceFlags">> => TraceFlags,
    <<"attributes">> => encode_attributes(Attributes),
    <<"events">> => encode_events(Events),
    <<"links">> => encode_links(Links),
    <<"status">> => encode_status(Status)
  }.

encode_span_kind(internal) -> 1;
encode_span_kind(server) -> 2;
encode_span_kind(client) -> 3;
encode_span_kind(producer) -> 4;
encode_span_kind(consumer) -> 5.

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

encode_events(Events) ->
  [encode_event(E) || E <- Events].

encode_event(#span_event{name = Name, timestamp = Timestamp, attributes = Attrs}) ->
  #{
    <<"name">> => Name,
    <<"timeUnixNano">> => integer_to_binary(Timestamp),
    <<"attributes">> => encode_attributes(Attrs)
  }.

encode_links(Links) ->
  [encode_link(L) || L <- Links].

encode_link(#span_link{ctx = #span_ctx{trace_id = TId, span_id = SId}, attributes = Attrs}) ->
  #{
    <<"traceId">> => base64:encode(TId),
    <<"spanId">> => base64:encode(SId),
    <<"attributes">> => encode_attributes(Attrs)
  }.

encode_status(unset) ->
  #{<<"code">> => 0};
encode_status(ok) ->
  #{<<"code">> => 1};
encode_status({error, Message}) ->
  #{<<"code">> => 2, <<"message">> => Message}.

send_request(Payload, #state{
  endpoint = Endpoint,
  traces_path = TracesPath,
  headers = ExtraHeaders,
  compression = Compression,
  timeout = Timeout
}) ->
  Url = <<Endpoint/binary, TracesPath/binary>>,

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
