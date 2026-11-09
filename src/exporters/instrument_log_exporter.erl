%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Log exporter manager for OpenTelemetry-compatible log export.
%%
%% This module manages log exporters and handles batch processing
%% of log records for efficient export.
%%
%% == Example Usage ==
%% ```
%% %% Register console exporter for logs
%% instrument_log_exporter:register(instrument_log_exporter_console:new()),
%%
%% %% Register OTLP exporter
%% instrument_log_exporter:register(instrument_log_exporter_otlp:new(#{
%%     endpoint => "http://localhost:4318"
%% })),
%%
%% %% Logs are exported when using instrument_logger with exporter mode
%% '''
-module(instrument_log_exporter).
-author("benoitc").

-behaviour(gen_server).

%% API
-export([
  start_link/0,
  register/1,
  unregister/1,
  list/0,
  export/1,
  export_batch/1,
  flush/0,
  shutdown/0,
  stats/0
]).

%% Exporter behaviour callbacks
-export([
  behaviour_info/1
]).

%% gen_server callbacks
-export([
  init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3,
  format_status/1
]).

-include("instrument_otel.hrl").

-define(ADMISSION, '$instrument_log_exporter_admission').

-record(state, {
  batcher :: instrument_export_batcher:batcher()
}).

-type exporter() :: #{
  module := module(),
  config := map(),
  state := term()
}.

-type export_result() :: ok | {error, term()}.

-export_type([exporter/0, export_result/0]).

%% @doc Behaviour callbacks for log exporters
behaviour_info(callbacks) ->
  [
    {exporter_init, 1},        %% exporter_init(Config) -> {ok, State} | {error, Reason}
    {exporter_export, 2},      %% exporter_export(LogRecords, State) -> {ok, NewState} | {error, Reason, NewState}
    {exporter_shutdown, 1},    %% exporter_shutdown(State) -> ok
    {exporter_force_flush, 1}  %% exporter_force_flush(State) -> {ok, NewState}
    %% Optional: export_async() -> true runs exports in a separate process,
    %% so a slow exporter does not block the server. Only for exporters whose
    %% state is not tied to the process that called init (no raw files).
  ];
behaviour_info(_) ->
  undefined.

%% ============================================================================
%% API
%% ============================================================================

%% @doc Starts the log exporter manager.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Registers a log exporter.
-spec register(#{module := module(), config => map()}) -> ok | {error, term()}.
register(#{module := Module} = Exporter) ->
  Config = maps:get(config, Exporter, #{}),
  gen_server:call(?MODULE, {register, Module, Config}).

%% @doc Unregisters a log exporter.
-spec unregister(module()) -> ok.
unregister(Module) ->
  gen_server:call(?MODULE, {unregister, Module}).

%% @doc Lists all registered exporters.
-spec list() -> [module()].
list() ->
  gen_server:call(?MODULE, list).

%% @doc Exports a single log record (adds to batch). Dropped when the queue
%% is full (`log_exporter_max_queue_size' or OTEL_BLRP_MAX_QUEUE_SIZE,
%% default 2048).
-spec export(#log_record{}) -> ok.
export(LogRecord) ->
  case instrument_admission:admit(?ADMISSION, 1) of
    true -> gen_server:cast(?MODULE, {export, [LogRecord], 1});
    false -> ok
  end.

%% @doc Exports multiple log records. Dropped when they do not fit in the
%% queue.
-spec export_batch([#log_record{}]) -> ok.
export_batch([]) ->
  ok;
export_batch(LogRecords) ->
  N = length(LogRecords),
  case instrument_admission:admit(?ADMISSION, N) of
    true -> gen_server:cast(?MODULE, {export, LogRecords, N});
    false -> ok
  end.

%% @doc Exports all pending log records and flushes the exporters.
-spec flush() -> ok.
flush() ->
  gen_server:call(?MODULE, flush, export_timeout() + 5000).

%% @doc Exports pending log records and shuts down all exporters.
-spec shutdown() -> ok.
shutdown() ->
  gen_server:call(?MODULE, shutdown, 2 * export_timeout() + 5000).

%% @doc Returns `#{queued, dropped, max_queue}'.
-spec stats() -> #{queued := non_neg_integer(), dropped := non_neg_integer(),
                   max_queue := pos_integer()}.
stats() ->
  #{queued => instrument_admission:queued(?ADMISSION),
    dropped => instrument_admission:dropped(?ADMISSION),
    max_queue => max_queue()}.

%% ============================================================================
%% gen_server callbacks
%% ============================================================================

init([]) ->
  %% Trap exits so terminate/2 exports what is queued on shutdown.
  process_flag(trap_exit, true),
  Batcher = instrument_export_batcher:new(#{
    admission => ?ADMISSION,
    callbacks => callbacks(),
    max_queue => max_queue(),
    export_timeout => export_timeout()
  }),
  %% After a restart, initialize the exporters registered before the crash.
  B = lists:foldl(fun({Module, Config}, Acc) ->
        case instrument_lib:safe_apply(Module, exporter_init, [Config], error) of
          {ok, S} ->
            instrument_export_batcher:add_exporter(
              #{module => Module, config => Config, state => S}, Acc);
          _ ->
            Acc
        end
      end, Batcher, instrument_registrations:list(log_exporter)),
  {ok, #state{batcher = B}}.

handle_call({register, Module, Config}, _From, #state{batcher = B} = State) ->
  case instrument_lib:safe_call(fun() -> Module:exporter_init(Config) end, {error, init_failed}) of
    {ok, ExporterState} ->
      Exporter = #{module => Module, config => Config, state => ExporterState},
      ok = instrument_registrations:put(log_exporter, Module, Config),
      {reply, ok, State#state{batcher = instrument_export_batcher:add_exporter(Exporter, B)}};
    {error, Reason} ->
      {reply, {error, Reason}, State}
  end;

handle_call({unregister, Module}, _From, #state{batcher = B} = State) ->
  {Removed, B1} = instrument_export_batcher:remove_exporter(Module, B),
  lists:foreach(fun(#{module := M, state := S}) ->
    instrument_lib:safe_apply(M, exporter_shutdown, [S], ok)
  end, Removed),
  ok = instrument_registrations:delete(log_exporter, Module),
  {reply, ok, State#state{batcher = B1}};

handle_call(list, _From, #state{batcher = B} = State) ->
  Modules = [M || #{module := M} <- instrument_export_batcher:exporters(B)],
  {reply, Modules, State};

handle_call(flush, From, #state{batcher = B} = State) ->
  {noreply, State#state{batcher = instrument_export_batcher:flush(From, B)}};

handle_call(shutdown, _From, #state{batcher = B} = State) ->
  B1 = instrument_export_batcher:shutdown_exporters(instrument_export_batcher:drain(B)),
  ok = instrument_registrations:clear(log_exporter),
  {reply, ok, State#state{batcher = B1}};

handle_call(_Request, _From, State) ->
  {reply, {error, unknown_request}, State}.

handle_cast({export, LogRecords, N}, #state{batcher = B} = State) ->
  {noreply, State#state{batcher = instrument_export_batcher:add(LogRecords, N, B)}};

handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info(Info, #state{batcher = B} = State) ->
  case instrument_export_batcher:handle_info(Info, B) of
    {ok, B1} -> {noreply, State#state{batcher = B1}};
    ignore -> {noreply, State}
  end.

terminate(_Reason, #state{batcher = B}) ->
  _ = instrument_export_batcher:shutdown_exporters(instrument_export_batcher:drain(B)),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% Exporter state holds connection settings such as authorization headers;
%% keep them out of crash reports and sys:get_status/1.
format_status(Status) ->
  instrument_lib:redact_status(Status).

%% ============================================================================
%% Internal functions
%% ============================================================================

callbacks() ->
  #{export => fun(M, Records, S) ->
                case M:exporter_export(Records, S) of
                  {ok, NewS} -> NewS;
                  {error, _Reason, NewS} -> NewS;
                  _ -> S
                end
              end,
    shutdown => fun(M, S) -> M:exporter_shutdown(S) end,
    force_flush => fun(M, S) ->
                     case M:exporter_force_flush(S) of
                       {ok, NewS} -> NewS;
                       _ -> S
                     end
                   end}.

max_queue() ->
  case application:get_env(instrument, log_exporter_max_queue_size) of
    {ok, N} when is_integer(N), N > 0 -> N;
    _ ->
      case os:getenv("OTEL_BLRP_MAX_QUEUE_SIZE") of
        false -> 2048;
        V -> try list_to_integer(V) of
               I when I > 0 -> I;
               _ -> 2048
             catch _:_ -> 2048
             end
      end
  end.

export_timeout() ->
  30000.
