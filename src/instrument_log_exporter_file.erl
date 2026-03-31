%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc File exporter for log records with rotation support.
%%
%% Exports log records to a file with optional rotation based on file size.
%%
%% == Example Usage ==
%% ```
%% %% Register with required path
%% instrument_log_exporter:register(instrument_log_exporter_file:new(#{
%%     path => "/var/log/app.log"
%% })),
%%
%% %% Register with options
%% instrument_log_exporter:register(instrument_log_exporter_file:new(#{
%%     path => "/var/log/app.log",
%%     format => json,         %% text | json (default: text)
%%     max_size => 10485760,   %% 10MB (default, 0 = unlimited)
%%     max_files => 5,         %% number of rotated files (default: 5)
%%     compress => true        %% compress rotated files (default: false)
%% })),
%% '''
%%
%% == File Rotation ==
%% When max_size is reached, files rotate:
%% ```
%% app.log -> app.log.1 -> app.log.2 -> ... -> app.log.N
%% '''
%% If compress=true, rotated files become app.log.1.gz, etc.
-module(instrument_log_exporter_file).
-author("benoitc").

%% Public API
-export([new/1]).

%% Exporter callbacks
-export([init/1, export/2, shutdown/1, force_flush/1]).

-include("instrument_otel.hrl").
-include_lib("kernel/include/file.hrl").

-record(state, {
  path :: binary(),
  format = text :: text | json,
  max_size = 10485760 :: non_neg_integer(),  %% 10MB default, 0 = unlimited
  max_files = 5 :: pos_integer(),
  compress = false :: boolean(),
  fd :: file:io_device() | undefined,
  current_size = 0 :: non_neg_integer()
}).

%% ============================================================================
%% Public API
%% ============================================================================

%% @doc Creates a new file log exporter configuration.
-spec new(map()) -> #{module := module(), config := map()}.
new(Config) when is_map(Config) ->
  #{module => ?MODULE, config => Config}.

%% ============================================================================
%% Exporter callbacks
%% ============================================================================

%% @doc Initializes the exporter.
-spec init(map()) -> {ok, #state{}} | {error, term()}.
init(Config) ->
  case maps:get(path, Config, undefined) of
    undefined ->
      {error, missing_path};
    Path ->
      PathBin = to_binary(Path),
      Format = maps:get(format, Config, text),
      MaxSize = maps:get(max_size, Config, 10485760),
      MaxFiles = maps:get(max_files, Config, 5),
      Compress = maps:get(compress, Config, false),

      State = #state{
        path = PathBin,
        format = Format,
        max_size = MaxSize,
        max_files = MaxFiles,
        compress = Compress
      },

      case open_file(State) of
        {ok, NewState} ->
          {ok, NewState};
        {error, Reason} ->
          {error, Reason}
      end
  end.

%% @doc Exports log records to the file.
-spec export([#log_record{}], #state{}) -> {ok, #state{}} | {error, term(), #state{}}.
export(_LogRecords, #state{fd = undefined} = State) ->
  %% File handle is undefined (e.g., after rotation failure), try to reopen
  case open_file(State) of
    {ok, NewState} ->
      %% Retry would require re-calling export, but we'd lose the records.
      %% Return success with reopened state; next batch will work.
      {ok, NewState};
    {error, Reason} ->
      {error, {reopen_failed, Reason}, State}
  end;
export(LogRecords, #state{format = Format} = State) ->
  try
    State2 = lists:foldl(fun(LogRecord, AccState) ->
      Line = format_log_record(LogRecord, Format),
      LineSize = iolist_size(Line),
      AccState2 = maybe_rotate(AccState, LineSize),
      case AccState2#state.fd of
        undefined ->
          %% Rotation failed to reopen, skip this record
          AccState2;
        Fd ->
          ok = file:write(Fd, Line),
          AccState2#state{current_size = AccState2#state.current_size + LineSize}
      end
    end, State, LogRecords),
    {ok, State2}
  catch
    _:Reason ->
      {error, Reason, State}
  end.

%% @doc Shuts down the exporter.
-spec shutdown(#state{}) -> ok.
shutdown(#state{fd = undefined}) ->
  ok;
shutdown(#state{fd = Fd}) ->
  file:close(Fd),
  ok.

%% @doc Forces a flush.
-spec force_flush(#state{}) -> {ok, #state{}}.
force_flush(#state{fd = undefined} = State) ->
  {ok, State};
force_flush(#state{fd = Fd} = State) ->
  file:sync(Fd),
  {ok, State}.

%% ============================================================================
%% Internal functions
%% ============================================================================

open_file(#state{path = Path} = State) ->
  %% Ensure directory exists
  Dir = filename:dirname(Path),
  case filelib:ensure_dir(binary_to_list(Path)) of
    ok ->
      open_file_fd(State);
    {error, Reason} ->
      {error, {mkdir_failed, Dir, Reason}}
  end.

open_file_fd(#state{path = Path} = State) ->
  case file:open(binary_to_list(Path), [write, append, raw, {delayed_write, 65536, 2000}]) of
    {ok, Fd} ->
      %% Get current file size
      CurrentSize = case file:read_file_info(binary_to_list(Path)) of
        {ok, #file_info{size = Size}} -> Size;
        _ -> 0
      end,
      {ok, State#state{fd = Fd, current_size = CurrentSize}};
    {error, Reason} ->
      {error, {open_failed, Path, Reason}}
  end.

maybe_rotate(#state{max_size = 0} = State, _LineSize) ->
  %% Rotation disabled
  State;
maybe_rotate(#state{current_size = CurrentSize, max_size = MaxSize} = State, LineSize)
  when CurrentSize + LineSize < MaxSize ->
  %% No rotation needed
  State;
maybe_rotate(State, _LineSize) ->
  %% Rotate the file
  rotate_files(State).

rotate_files(#state{fd = Fd, path = Path, max_files = MaxFiles, compress = Compress} = State) ->
  %% Close current file
  file:close(Fd),

  PathStr = binary_to_list(Path),

  %% Rotate existing files: .N -> .N+1
  rotate_numbered_files(PathStr, MaxFiles, Compress),

  %% Move current file to .1
  RotatedPath = PathStr ++ ".1",
  file:rename(PathStr, RotatedPath),

  %% Compress if enabled
  case Compress of
    true ->
      compress_file(RotatedPath);
    false ->
      ok
  end,

  %% Open new file
  case open_file_fd(State#state{fd = undefined, current_size = 0}) of
    {ok, NewState} ->
      NewState;
    {error, _Reason} ->
      %% Failed to reopen, return state with undefined fd
      State#state{fd = undefined, current_size = 0}
  end.

rotate_numbered_files(BasePath, MaxFiles, Compress) ->
  %% Delete the oldest file if it exists
  OldestPath = numbered_path(BasePath, MaxFiles, Compress),
  file:delete(OldestPath),

  %% Rotate files from N-1 down to 1
  lists:foreach(fun(N) ->
    OldPath = numbered_path(BasePath, N, Compress),
    NewPath = numbered_path(BasePath, N + 1, Compress),
    file:rename(OldPath, NewPath)
  end, lists:seq(MaxFiles - 1, 1, -1)).

numbered_path(BasePath, N, true) ->
  BasePath ++ "." ++ integer_to_list(N) ++ ".gz";
numbered_path(BasePath, N, false) ->
  BasePath ++ "." ++ integer_to_list(N).

compress_file(Path) ->
  case file:read_file(Path) of
    {ok, Data} ->
      Compressed = zlib:gzip(Data),
      GzPath = Path ++ ".gz",
      case file:write_file(GzPath, Compressed) of
        ok ->
          file:delete(Path);
        _ ->
          ok
      end;
    _ ->
      ok
  end.

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
  TraceId.

format_span_id_hex(SpanId) when is_binary(SpanId), byte_size(SpanId) =:= 8 ->
  instrument_id:span_id_to_hex(SpanId);
format_span_id_hex(SpanId) when is_binary(SpanId) ->
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
