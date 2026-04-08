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
  shutdown/0
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
  code_change/3
]).

-include("instrument_otel.hrl").

-record(state, {
  exporters = [] :: [exporter()],
  batch = [] :: [#log_record{}],
  batch_size = 512 :: pos_integer(),
  batch_timeout = 5000 :: pos_integer(),
  timer_ref :: reference() | undefined
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

%% @doc Exports a single log record (adds to batch).
-spec export(#log_record{}) -> ok.
export(LogRecord) ->
  gen_server:cast(?MODULE, {export, LogRecord}).

%% @doc Exports multiple log records immediately.
-spec export_batch([#log_record{}]) -> ok.
export_batch(LogRecords) ->
  gen_server:cast(?MODULE, {export_batch, LogRecords}).

%% @doc Forces a flush of all pending log records.
-spec flush() -> ok.
flush() ->
  gen_server:call(?MODULE, flush, 30000).

%% @doc Shuts down all exporters.
-spec shutdown() -> ok.
shutdown() ->
  gen_server:call(?MODULE, shutdown, 30000).

%% ============================================================================
%% gen_server callbacks
%% ============================================================================

init([]) ->
  {ok, #state{}}.

handle_call({register, Module, Config}, _From, State) ->
  case Module:exporter_init(Config) of
    {ok, ExporterState} ->
      Exporter = #{module => Module, config => Config, state => ExporterState},
      NewExporters = [Exporter | State#state.exporters],
      {reply, ok, State#state{exporters = NewExporters}};
    {error, Reason} ->
      {reply, {error, Reason}, State}
  end;

handle_call({unregister, Module}, _From, State) ->
  {Removed, Remaining} = lists:partition(
    fun(#{module := M}) -> M =:= Module end,
    State#state.exporters
  ),
  %% Shutdown removed exporters
  lists:foreach(fun(#{module := M, state := S}) ->
    catch M:exporter_shutdown(S)
  end, Removed),
  {reply, ok, State#state{exporters = Remaining}};

handle_call(list, _From, State) ->
  Modules = [M || #{module := M} <- State#state.exporters],
  {reply, Modules, State};

handle_call(flush, _From, State) ->
  State2 = do_flush(State),
  State3 = do_force_flush(State2),
  {reply, ok, State3};

handle_call(shutdown, _From, State) ->
  State2 = do_flush(State),
  lists:foreach(fun(#{module := M, state := S}) ->
    catch M:exporter_shutdown(S)
  end, State2#state.exporters),
  {reply, ok, State2#state{exporters = []}};

handle_call(_Request, _From, State) ->
  {reply, {error, unknown_request}, State}.

handle_cast({export, LogRecord}, State) ->
  NewBatch = [LogRecord | State#state.batch],
  State2 = maybe_start_timer(State#state{batch = NewBatch}),
  State3 = maybe_flush_batch(State2),
  {noreply, State3};

handle_cast({export_batch, LogRecords}, State) ->
  NewBatch = LogRecords ++ State#state.batch,
  State2 = State#state{batch = NewBatch},
  State3 = do_flush(State2),
  {noreply, State3};

handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info(batch_timeout, State) ->
  State2 = do_flush(State#state{timer_ref = undefined}),
  {noreply, State2};

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, State) ->
  %% Final flush and shutdown
  State2 = do_flush(State),
  lists:foreach(fun(#{module := M, state := S}) ->
    catch M:exporter_shutdown(S)
  end, State2#state.exporters),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% ============================================================================
%% Internal functions
%% ============================================================================

maybe_start_timer(#state{timer_ref = undefined, batch_timeout = Timeout} = State) ->
  Ref = erlang:send_after(Timeout, self(), batch_timeout),
  State#state{timer_ref = Ref};
maybe_start_timer(State) ->
  State.

maybe_flush_batch(#state{batch = Batch, batch_size = MaxSize} = State) when length(Batch) >= MaxSize ->
  do_flush(State);
maybe_flush_batch(State) ->
  State.

do_flush(#state{batch = []} = State) ->
  cancel_timer(State);
do_flush(#state{batch = Batch, exporters = Exporters} = State) ->
  %% Export to all registered exporters
  NewExporters = lists:map(fun(#{module := M, state := S} = Exporter) ->
    %% Check if exporter is enabled at runtime
    case instrument_config:is_exporter_enabled(M) of
      false ->
        %% Skip disabled exporter
        Exporter;
      true ->
        case catch M:exporter_export(Batch, S) of
          {ok, NewState} ->
            Exporter#{state => NewState};
          {error, _Reason, NewState} ->
            Exporter#{state => NewState};
          _ ->
            Exporter
        end
    end
  end, Exporters),
  cancel_timer(State#state{batch = [], exporters = NewExporters}).

do_force_flush(#state{exporters = Exporters} = State) ->
  %% Force flush all registered exporters
  NewExporters = lists:map(fun(#{module := M, state := S} = Exporter) ->
    case catch M:exporter_force_flush(S) of
      {ok, NewState} ->
        Exporter#{state => NewState};
      _ ->
        Exporter
    end
  end, Exporters),
  State#state{exporters = NewExporters}.

cancel_timer(#state{timer_ref = undefined} = State) ->
  State;
cancel_timer(#state{timer_ref = Ref} = State) ->
  erlang:cancel_timer(Ref),
  State#state{timer_ref = undefined}.
