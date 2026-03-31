%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Console exporter for spans.
%%
%% Exports spans to stdout for debugging and development.
%%
%% == Example Usage ==
%% ```
%% %% Register with default options
%% instrument_exporter:register(instrument_exporter_console:new()),
%%
%% %% Register with options
%% instrument_exporter:register(instrument_exporter_console:new(#{
%%     format => json,      %% json | text (default: text)
%%     output => standard_io %% standard_io | standard_error | {file, Path}
%% })),
%% '''
-module(instrument_exporter_console).
-author("benoitc").

%% Public API
-export([new/0, new/1]).

%% Exporter callbacks
-export([init/1, export/2, shutdown/1, force_flush/1]).

-include("instrument_otel.hrl").

-record(state, {
  format = text :: text | json,
  output = standard_io :: standard_io | standard_error | {file, file:io_device()}
}).

%% ============================================================================
%% Public API
%% ============================================================================

%% @doc Creates a new console exporter configuration with defaults.
-spec new() -> #{module := module(), config := map()}.
new() ->
  new(#{}).

%% @doc Creates a new console exporter configuration.
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
  OutputSpec = maps:get(output, Config, standard_io),
  case open_output(OutputSpec) of
    {ok, Output} ->
      {ok, #state{format = Format, output = Output}};
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Exports spans to the console.
-spec export([#span{}], #state{}) -> {ok, #state{}} | {error, term(), #state{}}.
export(Spans, #state{format = Format, output = Output} = State) ->
  try
    lists:foreach(fun(Span) ->
      Line = format_span(Span, Format),
      io:put_chars(Output, Line)
    end, Spans),
    {ok, State}
  catch
    _:Reason ->
      {error, Reason, State}
  end.

%% @doc Shuts down the exporter.
-spec shutdown(#state{}) -> ok.
shutdown(#state{output = {file, Fd}}) ->
  file:close(Fd),
  ok;
shutdown(_State) ->
  ok.

%% @doc Forces a flush (no-op for console).
-spec force_flush(#state{}) -> {ok, #state{}}.
force_flush(State) ->
  {ok, State}.

%% ============================================================================
%% Internal functions
%% ============================================================================

open_output(standard_io) ->
  {ok, standard_io};
open_output(standard_error) ->
  {ok, standard_error};
open_output({file, Path}) ->
  case file:open(Path, [write, append]) of
    {ok, Fd} -> {ok, {file, Fd}};
    Error -> Error
  end.

format_span(Span, text) ->
  format_span_text(Span);
format_span(Span, json) ->
  format_span_json(Span).

format_span_text(#span{
  name = Name,
  ctx = #span_ctx{trace_id = TraceId, span_id = SpanId},
  parent_ctx = ParentCtx,
  kind = Kind,
  start_time = StartTime,
  end_time = EndTime,
  attributes = Attributes,
  events = Events,
  status = Status
}) ->
  TraceIdHex = instrument_id:trace_id_to_hex(TraceId),
  SpanIdHex = instrument_id:span_id_to_hex(SpanId),
  ParentSpanIdHex = case ParentCtx of
    #span_ctx{span_id = PSpanId} -> instrument_id:span_id_to_hex(PSpanId);
    undefined -> <<"none">>
  end,
  Duration = case EndTime of
    undefined -> <<"in_progress">>;
    _ -> format_duration(EndTime - StartTime)
  end,
  StatusStr = format_status(Status),
  AttrsStr = format_attributes_text(Attributes),
  EventsStr = format_events_text(Events),

  io_lib:format(
    "~n=== SPAN ===~n"
    "Name:       ~s~n"
    "TraceId:    ~s~n"
    "SpanId:     ~s~n"
    "ParentId:   ~s~n"
    "Kind:       ~p~n"
    "Duration:   ~s~n"
    "Status:     ~s~n"
    "~s"
    "~s"
    "============~n",
    [Name, TraceIdHex, SpanIdHex, ParentSpanIdHex, Kind, Duration, StatusStr, AttrsStr, EventsStr]
  ).

format_span_json(#span{
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
  TraceIdHex = instrument_id:trace_id_to_hex(TraceId),
  SpanIdHex = instrument_id:span_id_to_hex(SpanId),
  ParentSpanIdHex = case ParentCtx of
    #span_ctx{span_id = PSpanId} -> instrument_id:span_id_to_hex(PSpanId);
    undefined -> null
  end,

  SpanMap = #{
    <<"name">> => Name,
    <<"traceId">> => TraceIdHex,
    <<"spanId">> => SpanIdHex,
    <<"parentSpanId">> => ParentSpanIdHex,
    <<"kind">> => atom_to_binary(Kind, utf8),
    <<"startTimeUnixNano">> => StartTime,
    <<"endTimeUnixNano">> => EndTime,
    <<"traceFlags">> => TraceFlags,
    <<"attributes">> => format_attributes_json(Attributes),
    <<"events">> => format_events_json(Events),
    <<"links">> => format_links_json(Links),
    <<"status">> => format_status_json(Status)
  },

  [json:encode(SpanMap), "\n"].

format_duration(Nanos) when Nanos < 1000 ->
  io_lib:format("~Bns", [Nanos]);
format_duration(Nanos) when Nanos < 1000000 ->
  io_lib:format("~.2fus", [Nanos / 1000]);
format_duration(Nanos) when Nanos < 1000000000 ->
  io_lib:format("~.2fms", [Nanos / 1000000]);
format_duration(Nanos) ->
  io_lib:format("~.2fs", [Nanos / 1000000000]).

format_status(unset) -> "UNSET";
format_status(ok) -> "OK";
format_status({error, Msg}) -> io_lib:format("ERROR: ~s", [Msg]).

format_status_json(unset) -> #{<<"code">> => <<"UNSET">>};
format_status_json(ok) -> #{<<"code">> => <<"OK">>};
format_status_json({error, Msg}) -> #{<<"code">> => <<"ERROR">>, <<"message">> => Msg}.

format_attributes_text(Attrs) when map_size(Attrs) =:= 0 ->
  "";
format_attributes_text(Attrs) ->
  Lines = maps:fold(fun(K, V, Acc) ->
    [io_lib:format("  ~s: ~p~n", [K, V]) | Acc]
  end, [], Attrs),
  ["Attributes:~n" | lists:reverse(Lines)].

format_attributes_json(Attrs) ->
  maps:fold(fun(K, V, Acc) ->
    Key = to_binary(K),
    maps:put(Key, format_attr_value(V), Acc)
  end, #{}, Attrs).

format_attr_value(V) when is_binary(V) -> V;
format_attr_value(V) when is_atom(V) -> atom_to_binary(V, utf8);
format_attr_value(V) when is_integer(V) -> V;
format_attr_value(V) when is_float(V) -> V;
format_attr_value(V) when is_boolean(V) -> V;
format_attr_value(V) when is_list(V) -> [format_attr_value(E) || E <- V];
format_attr_value(V) -> iolist_to_binary(io_lib:format("~p", [V])).

format_events_text([]) ->
  "";
format_events_text(Events) ->
  Lines = lists:map(fun(#span_event{name = Name, timestamp = Ts, attributes = Attrs}) ->
    AttrStr = case map_size(Attrs) of
      0 -> "";
      _ -> io_lib:format(" ~p", [Attrs])
    end,
    io_lib:format("  @~s: ~s~s~n", [format_timestamp(Ts), Name, AttrStr])
  end, Events),
  ["Events:~n" | Lines].

format_events_json(Events) ->
  [#{
    <<"name">> => Name,
    <<"timeUnixNano">> => Ts,
    <<"attributes">> => format_attributes_json(Attrs)
  } || #span_event{name = Name, timestamp = Ts, attributes = Attrs} <- Events].

format_links_json(Links) ->
  [#{
    <<"traceId">> => instrument_id:trace_id_to_hex(TId),
    <<"spanId">> => instrument_id:span_id_to_hex(SId),
    <<"attributes">> => format_attributes_json(Attrs)
  } || #span_link{ctx = #span_ctx{trace_id = TId, span_id = SId}, attributes = Attrs} <- Links].

format_timestamp(Ts) ->
  Micros = Ts div 1000,
  Seconds = Micros div 1000000,
  Micro = Micros rem 1000000,
  {{Y, M, D}, {H, Mi, S}} = calendar:system_time_to_universal_time(Seconds, second),
  io_lib:format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0B.~6..0BZ",
    [Y, M, D, H, Mi, S, Micro]).

to_binary(V) when is_binary(V) -> V;
to_binary(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_binary(V) when is_list(V) -> list_to_binary(V).
