%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Console exporter for log records.
%%
%% Exports log records to stdout or stderr for debugging and development.
%%
%% == Example Usage ==
%% ```
%% %% Register with default options
%% instrument_log_exporter:register(instrument_log_exporter_console:new()),
%%
%% %% Register with options
%% instrument_log_exporter:register(instrument_log_exporter_console:new(#{
%%     format => json,      %% json | text (default: text)
%%     output => standard_io %% standard_io | standard_error
%% })),
%% '''
%%
%% == Text Format ==
%% ```
%% [2026-03-31T12:00:00Z] INFO [trace_id=abc span_id=xyz] User logged in {"user":"john"}
%% '''
%%
%% == JSON Format (OTLP-compatible) ==
%% ```
%% {"timestamp":"...","severityText":"INFO","body":"User logged in",...}
%% '''
-module(instrument_log_exporter_console).
-author("benoitc").

%% Public API
-export([new/0, new/1]).

%% Exporter callbacks
-export([init/1, export/2, shutdown/1, force_flush/1]).

-include("instrument_otel.hrl").

-record(state, {
  format = text :: text | json,
  output = standard_io :: standard_io | standard_error
}).

%% ============================================================================
%% Public API
%% ============================================================================

%% @doc Creates a new console log exporter configuration with defaults.
-spec new() -> #{module := module(), config := map()}.
new() ->
  new(#{}).

%% @doc Creates a new console log exporter configuration.
-spec new(map()) -> #{module := module(), config := map()}.
new(Config) when is_map(Config) ->
  #{module => ?MODULE, config => Config}.

%% ============================================================================
%% Exporter callbacks
%% ============================================================================

%% @doc Initializes the exporter.
-spec init(map()) -> {ok, #state{}} | {error, term()}.
init(Config) ->
  Format = maps:get(format, Config, text),
  Output = maps:get(output, Config, standard_io),
  {ok, #state{format = Format, output = Output}}.

%% @doc Exports log records to the console.
-spec export([#log_record{}], #state{}) -> {ok, #state{}} | {error, term(), #state{}}.
export(LogRecords, #state{format = Format, output = Output} = State) ->
  try
    lists:foreach(fun(LogRecord) ->
      Line = format_log_record(LogRecord, Format),
      io:put_chars(Output, Line)
    end, LogRecords),
    {ok, State}
  catch
    _:Reason ->
      {error, Reason, State}
  end.

%% @doc Shuts down the exporter.
-spec shutdown(#state{}) -> ok.
shutdown(_State) ->
  ok.

%% @doc Forces a flush (no-op for console).
-spec force_flush(#state{}) -> {ok, #state{}}.
force_flush(State) ->
  {ok, State}.

%% ============================================================================
%% Internal functions
%% ============================================================================

format_log_record(LogRecord, text) ->
  format_log_record_text(LogRecord);
format_log_record(LogRecord, json) ->
  format_log_record_json(LogRecord).

format_log_record_text(#log_record{
  timestamp = Timestamp,
  severity_text = SeverityText,
  body = Body,
  attributes = Attributes,
  trace_id = TraceId,
  span_id = SpanId
}) ->
  TimeStr = format_timestamp(Timestamp),
  SevStr = case SeverityText of
    undefined -> <<"INFO">>;
    S -> S
  end,
  TraceInfo = format_trace_info(TraceId, SpanId),
  BodyStr = format_body(Body),
  AttrsStr = format_attributes_text(Attributes),
  io_lib:format("[~s] ~s~s ~s~s~n", [TimeStr, SevStr, TraceInfo, BodyStr, AttrsStr]).

format_log_record_json(#log_record{
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
    <<"body">> => #{<<"stringValue">> => format_body_binary(Body)},
    <<"attributes">> => format_attributes_json(Attributes)
  },
  LogMap2 = add_trace_context_json(LogMap, TraceId, SpanId, TraceFlags),
  [json:encode(LogMap2), "\n"].

ensure_timestamp(Ts) when is_integer(Ts) ->
  Ts;
ensure_timestamp(_) ->
  erlang:system_time(nanosecond).

ensure_integer(undefined, Default) -> Default;
ensure_integer(N, _) when is_integer(N) -> N.

ensure_binary(undefined, Default) -> Default;
ensure_binary(B, _) when is_binary(B) -> B.

add_trace_context_json(Map, undefined, _, _) ->
  Map;
add_trace_context_json(Map, TraceId, SpanId, TraceFlags) ->
  Map2 = Map#{<<"traceId">> => format_trace_id_hex(TraceId)},
  Map3 = case SpanId of
    undefined -> Map2;
    _ -> Map2#{<<"spanId">> => format_span_id_hex(SpanId)}
  end,
  case TraceFlags of
    undefined -> Map3;
    _ -> Map3#{<<"traceFlags">> => TraceFlags}
  end.

format_trace_id_hex(TraceId) when is_binary(TraceId), byte_size(TraceId) =:= 16 ->
  instrument_id:trace_id_to_hex(TraceId);
format_trace_id_hex(TraceId) when is_binary(TraceId) ->
  %% Already hex
  TraceId.

format_span_id_hex(SpanId) when is_binary(SpanId), byte_size(SpanId) =:= 8 ->
  instrument_id:span_id_to_hex(SpanId);
format_span_id_hex(SpanId) when is_binary(SpanId) ->
  %% Already hex
  SpanId.

format_timestamp(Ts) when is_integer(Ts) ->
  Micros = Ts div 1000,
  Seconds = Micros div 1000000,
  Micro = Micros rem 1000000,
  {{Y, M, D}, {H, Mi, S}} = calendar:system_time_to_universal_time(Seconds, second),
  io_lib:format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0B.~6..0BZ",
    [Y, M, D, H, Mi, S, Micro]).

format_trace_info(undefined, _) ->
  "";
format_trace_info(_, undefined) ->
  "";
format_trace_info(TraceId, SpanId) ->
  TraceIdHex = format_trace_id_hex(TraceId),
  SpanIdHex = format_span_id_hex(SpanId),
  io_lib:format(" [trace_id=~s span_id=~s]", [TraceIdHex, SpanIdHex]).

format_body(Body) when is_binary(Body) ->
  Body;
format_body(Body) when is_list(Body) ->
  list_to_binary(Body);
format_body({Format, Args}) when is_list(Format) ->
  iolist_to_binary(io_lib:format(Format, Args));
format_body({report, Report}) when is_map(Report) ->
  iolist_to_binary(io_lib:format("~p", [Report]));
format_body({string, String}) ->
  iolist_to_binary(String);
format_body(Body) ->
  iolist_to_binary(io_lib:format("~p", [Body])).

format_body_binary(Body) when is_binary(Body) ->
  Body;
format_body_binary(Body) when is_list(Body) ->
  iolist_to_binary(Body);
format_body_binary({Format, Args}) when is_list(Format) ->
  iolist_to_binary(io_lib:format(Format, Args));
format_body_binary({report, Report}) ->
  iolist_to_binary(io_lib:format("~p", [Report]));
format_body_binary({string, String}) ->
  iolist_to_binary(String);
format_body_binary(Body) ->
  iolist_to_binary(io_lib:format("~p", [Body])).

format_attributes_text(Attrs) when map_size(Attrs) =:= 0 ->
  "";
format_attributes_text(Attrs) ->
  try
    [" ", json:encode(Attrs)]
  catch
    _:_ ->
      io_lib:format(" ~p", [Attrs])
  end.

format_attributes_json(Attrs) ->
  maps:fold(fun(K, V, Acc) ->
    [format_attribute(K, V) | Acc]
  end, [], Attrs).

format_attribute(Key, Value) ->
  #{
    <<"key">> => to_binary(Key),
    <<"value">> => format_attr_value(Value)
  }.

format_attr_value(V) when is_binary(V) ->
  #{<<"stringValue">> => V};
format_attr_value(V) when is_atom(V) ->
  #{<<"stringValue">> => atom_to_binary(V, utf8)};
format_attr_value(V) when is_integer(V) ->
  #{<<"intValue">> => integer_to_binary(V)};
format_attr_value(V) when is_float(V) ->
  #{<<"doubleValue">> => V};
format_attr_value(true) ->
  #{<<"boolValue">> => true};
format_attr_value(false) ->
  #{<<"boolValue">> => false};
format_attr_value(V) when is_list(V) ->
  #{<<"arrayValue">> => #{<<"values">> => [format_attr_value(E) || E <- V]}};
format_attr_value(V) ->
  #{<<"stringValue">> => iolist_to_binary(io_lib:format("~p", [V]))}.

to_binary(V) when is_binary(V) -> V;
to_binary(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_binary(V) when is_list(V) -> list_to_binary(V).
