%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Erlang logger integration for OpenTelemetry-compatible instrumentation.
%%
%% This module installs a logger filter that automatically adds trace context
%% (trace_id, span_id) to log metadata when a span is active. It can also
%% export logs to registered log exporters.
%%
%% == Example Usage ==
%% ```
%% %% Install the logger integration (filter mode - adds trace context)
%% instrument_logger:install(),
%%
%% %% Install with exporter mode (sends logs to registered exporters)
%% instrument_log_exporter:register(instrument_log_exporter_console:new()),
%% instrument_logger:install(#{exporter => true}),
%%
%% %% Within a span, logs automatically include trace context
%% instrument_tracer:with_span(<<"my_operation">>, fun() ->
%%   logger:info("Processing request", #{user => User}),
%%   %% The log will include trace_id and span_id in metadata
%%   do_work()
%% end).
%% '''
-module(instrument_logger).
-author("benoitc").

-export([
  install/0,
  install/1,
  uninstall/0,
  add_trace_context/1,
  emit/1,
  emit/2,
  make_log_record/3,
  level_to_severity/1,
  level_to_severity_text/1
]).

%% Logger handler callbacks
-export([
  log/2,
  filter_config/1
]).

-include("instrument_otel.hrl").

-define(HANDLER_ID, instrument_otel_handler).
-define(EXPORTER_HANDLER_ID, instrument_log_exporter_handler).
-define(FILTER_ID, instrument_trace_context).

-type install_opts() :: #{
  handler => boolean(),        %% Install as handler (default: false)
  filter => boolean(),         %% Install as filter (default: true)
  exporter => boolean(),       %% Install as exporter handler (default: false)
  level => logger:level()      %% Minimum level for handler
}.

%% ============================================================================
%% Public API
%% ============================================================================

%% @doc Installs the logger integration with default options.
%% By default, installs a primary filter that adds trace context to all logs.
-spec install() -> ok | {error, term()}.
install() ->
  install(#{}).

%% @doc Installs the logger integration with options.
%% Options:
%% - filter => true (default) - Adds trace context to all logs
%% - handler => true - Installs a handler that formats and outputs logs
%% - exporter => true - Installs a handler that sends logs to registered exporters
%% - level => info (default) - Minimum level for handler
-spec install(install_opts()) -> ok | {error, term()}.
install(Opts) ->
  InstallFilter = maps:get(filter, Opts, true),
  InstallHandler = maps:get(handler, Opts, false),
  InstallExporter = maps:get(exporter, Opts, false),

  Result1 = case InstallFilter of
    true -> install_filter();
    false -> ok
  end,

  Result2 = case InstallHandler of
    true ->
      Level = maps:get(level, Opts, info),
      install_handler(Level);
    false -> ok
  end,

  Result3 = case InstallExporter of
    true ->
      Level2 = maps:get(level, Opts, info),
      install_exporter_handler(Level2);
    false -> ok
  end,

  case {Result1, Result2, Result3} of
    {ok, ok, ok} -> ok;
    {{error, _} = E, _, _} -> E;
    {_, {error, _} = E, _} -> E;
    {_, _, {error, _} = E} -> E
  end.

%% @doc Uninstalls the logger integration.
-spec uninstall() -> ok.
uninstall() ->
  %% Remove filter
  catch logger:remove_primary_filter(?FILTER_ID),
  %% Remove handler
  catch logger:remove_handler(?HANDLER_ID),
  %% Remove exporter handler
  catch logger:remove_handler(?EXPORTER_HANDLER_ID),
  ok.

%% @doc Adds trace context to a metadata map.
%% This can be used manually if you prefer not to install the filter.
-spec add_trace_context(map()) -> map().
add_trace_context(Metadata) when is_map(Metadata) ->
  case instrument_tracer:span_ctx() of
    undefined ->
      Metadata;
    #span_ctx{trace_id = TraceId, span_id = SpanId, trace_flags = Flags} ->
      Metadata#{
        trace_id => instrument_id:trace_id_to_hex(TraceId),
        span_id => instrument_id:span_id_to_hex(SpanId),
        trace_flags => Flags
      }
  end.

%% @doc Emits a log record with trace context.
-spec emit(term()) -> ok.
emit(Body) ->
  emit(info, Body).

%% @doc Emits a log record at the specified level with trace context.
-spec emit(logger:level(), term()) -> ok.
emit(Level, Body) ->
  Metadata = add_trace_context(#{}),
  logger:log(Level, Body, Metadata).

%% @doc Creates an OTel log record from a logger event.
-spec make_log_record(logger:level(), term(), map()) -> #log_record{}.
make_log_record(Level, Msg, Meta) ->
  Timestamp = maps:get(time, Meta, erlang:system_time(microsecond)) * 1000, %% Convert to nanoseconds
  ObservedTimestamp = erlang:system_time(nanosecond),

  %% Get trace context from metadata
  {TraceId, SpanId, TraceFlags} = get_trace_context(Meta),

  %% Extract attributes from metadata (excluding standard fields)
  Attributes = extract_attributes(Meta),

  #log_record{
    timestamp = Timestamp,
    observed_timestamp = ObservedTimestamp,
    severity_number = level_to_severity(Level),
    severity_text = level_to_severity_text(Level),
    body = format_body(Msg),
    attributes = Attributes,
    trace_id = TraceId,
    span_id = SpanId,
    trace_flags = TraceFlags,
    resource = undefined,
    scope = undefined
  }.

%% ============================================================================
%% Logger Handler Callbacks
%% ============================================================================

%% @doc Logger handler callback.
%% This is called when installed as a handler (not filter).
-spec log(logger:log_event(), logger:handler_config()) -> ok.
log(#{level := Level, msg := Msg, meta := Meta}, #{id := ?EXPORTER_HANDLER_ID}) ->
  %% Exporter mode: create log record and send to exporters
  EnrichedMeta = case maps:is_key(trace_id, Meta) of
    true -> Meta;
    false -> add_trace_context(Meta)
  end,
  LogRecord = make_log_record(Level, Msg, EnrichedMeta),
  instrument_log_exporter:export(LogRecord),
  ok;

log(#{level := Level, msg := Msg, meta := Meta}, Config) ->
  %% Standard handler mode: add trace context if not already present
  EnrichedMeta = case maps:is_key(trace_id, Meta) of
    true -> Meta;
    false -> add_trace_context(Meta)
  end,

  %% Format and output
  FormattedMsg = format_log(Level, Msg, EnrichedMeta, Config),
  io:put_chars(FormattedMsg),
  ok.

%% @doc Filter config callback for logger.
-spec filter_config(logger:filter_arg()) -> logger:filter_return().
filter_config(Log) ->
  Log.

%% ============================================================================
%% Internal Functions
%% ============================================================================

install_filter() ->
  Filter = fun trace_context_filter/2,
  case logger:add_primary_filter(?FILTER_ID, {Filter, #{}}) of
    ok -> ok;
    {error, {already_exist, _}} -> ok;
    Error -> Error
  end.

install_handler(Level) ->
  Config = #{
    level => Level,
    formatter => {?MODULE, #{}}
  },
  case logger:add_handler(?HANDLER_ID, ?MODULE, Config) of
    ok -> ok;
    {error, {already_exist, _}} -> ok;
    Error -> Error
  end.

install_exporter_handler(Level) ->
  Config = #{
    level => Level,
    formatter => {?MODULE, #{}}
  },
  case logger:add_handler(?EXPORTER_HANDLER_ID, ?MODULE, Config) of
    ok -> ok;
    {error, {already_exist, _}} -> ok;
    Error -> Error
  end.

%% Logger filter function that adds trace context to metadata
trace_context_filter(#{meta := Meta} = Log, _Extra) ->
  case maps:is_key(trace_id, Meta) of
    true ->
      %% Already has trace context
      Log;
    false ->
      %% Add trace context if available
      case instrument_tracer:span_ctx() of
        undefined ->
          Log;
        #span_ctx{trace_id = TraceId, span_id = SpanId, trace_flags = Flags} ->
          NewMeta = Meta#{
            trace_id => instrument_id:trace_id_to_hex(TraceId),
            span_id => instrument_id:span_id_to_hex(SpanId),
            trace_flags => Flags
          },
          Log#{meta => NewMeta}
      end
  end;
trace_context_filter(Log, _Extra) ->
  Log.

get_trace_context(Meta) ->
  TraceId = case maps:get(trace_id, Meta, undefined) of
    undefined -> undefined;
    TId when is_binary(TId), byte_size(TId) =:= 32 ->
      %% Hex format, convert back to binary
      instrument_id:hex_to_trace_id(TId);
    TId when is_binary(TId), byte_size(TId) =:= 16 ->
      TId;
    _ ->
      undefined
  end,
  SpanId = case maps:get(span_id, Meta, undefined) of
    undefined -> undefined;
    SId when is_binary(SId), byte_size(SId) =:= 16 ->
      %% Hex format, convert back to binary
      instrument_id:hex_to_span_id(SId);
    SId when is_binary(SId), byte_size(SId) =:= 8 ->
      SId;
    _ ->
      undefined
  end,
  TraceFlags = maps:get(trace_flags, Meta, undefined),
  {TraceId, SpanId, TraceFlags}.

extract_attributes(Meta) ->
  %% Filter out standard logger metadata fields
  StandardFields = [time, gl, pid, mfa, file, line, domain, report_cb,
                    trace_id, span_id, trace_flags],
  maps:fold(fun(K, V, Acc) ->
    case lists:member(K, StandardFields) of
      true -> Acc;
      false -> Acc#{K => V}
    end
  end, #{}, Meta).

format_body({Format, Args}) when is_list(Format) ->
  iolist_to_binary(io_lib:format(Format, Args));
format_body({report, Report}) ->
  iolist_to_binary(io_lib:format("~p", [Report]));
format_body({string, String}) ->
  iolist_to_binary(String);
format_body(Msg) when is_binary(Msg) ->
  Msg;
format_body(Msg) when is_list(Msg) ->
  iolist_to_binary(Msg);
format_body(Msg) ->
  iolist_to_binary(io_lib:format("~p", [Msg])).

format_log(Level, {Format, Args}, Meta, _Config) when is_list(Format) ->
  Msg = io_lib:format(Format, Args),
  format_line(Level, Msg, Meta);
format_log(Level, {report, Report}, Meta, _Config) ->
  Msg = io_lib:format("~p", [Report]),
  format_line(Level, Msg, Meta);
format_log(Level, {string, String}, Meta, _Config) ->
  format_line(Level, String, Meta);
format_log(Level, Msg, Meta, _Config) ->
  format_line(Level, io_lib:format("~p", [Msg]), Meta).

format_line(Level, Msg, Meta) ->
  Time = format_time(maps:get(time, Meta, erlang:system_time(microsecond))),
  TraceInfo = format_trace_info(Meta),
  LevelStr = string:uppercase(atom_to_list(Level)),
  io_lib:format("~s [~s]~s ~s~n", [Time, LevelStr, TraceInfo, Msg]).

format_time(Time) when is_integer(Time) ->
  Seconds = Time div 1000000,
  Micros = Time rem 1000000,
  {{Y, M, D}, {H, Mi, S}} = calendar:system_time_to_universal_time(Seconds, second),
  io_lib:format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0B.~6..0BZ",
    [Y, M, D, H, Mi, S, Micros]).

format_trace_info(Meta) ->
  case {maps:get(trace_id, Meta, undefined), maps:get(span_id, Meta, undefined)} of
    {undefined, _} -> "";
    {_, undefined} -> "";
    {TraceId, SpanId} ->
      io_lib:format(" [trace_id=~s span_id=~s]", [TraceId, SpanId])
  end.

%% ============================================================================
%% OTel Severity Mapping
%% ============================================================================

%% @doc Maps Erlang logger level to OTel severity number.
-spec level_to_severity(logger:level()) -> integer().
level_to_severity(emergency) -> ?SEVERITY_FATAL;
level_to_severity(alert) -> ?SEVERITY_FATAL2;
level_to_severity(critical) -> ?SEVERITY_ERROR4;
level_to_severity(error) -> ?SEVERITY_ERROR;
level_to_severity(warning) -> ?SEVERITY_WARN;
level_to_severity(notice) -> ?SEVERITY_INFO2;
level_to_severity(info) -> ?SEVERITY_INFO;
level_to_severity(debug) -> ?SEVERITY_DEBUG;
level_to_severity(_) -> ?SEVERITY_INFO.

%% @doc Maps Erlang logger level to OTel severity text.
-spec level_to_severity_text(logger:level()) -> binary().
level_to_severity_text(emergency) -> <<"FATAL">>;
level_to_severity_text(alert) -> <<"FATAL">>;
level_to_severity_text(critical) -> <<"ERROR">>;
level_to_severity_text(error) -> <<"ERROR">>;
level_to_severity_text(warning) -> <<"WARN">>;
level_to_severity_text(notice) -> <<"INFO">>;
level_to_severity_text(info) -> <<"INFO">>;
level_to_severity_text(debug) -> <<"DEBUG">>;
level_to_severity_text(_) -> <<"INFO">>.
