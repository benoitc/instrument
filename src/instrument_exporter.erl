%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Exporter management for spans and metrics.
%%
%% This module provides a registry for exporters and batch processing
%% of spans for efficient export.
%%
%% == Example Usage ==
%% ```
%% %% Register the console exporter
%% instrument_exporter:register(instrument_exporter_console:new()),
%%
%% %% Register OTLP exporter
%% instrument_exporter:register(instrument_exporter_otlp:new(#{
%%     endpoint => "http://localhost:4318"
%% })),
%%
%% %% Spans are automatically exported when they end
%% '''
-module(instrument_exporter).
-author("benoitc").

-behaviour(gen_server).

%% API
-export([
  start_link/0,
  register/1,
  unregister/1,
  list/0,
  export_span/1,
  export_spans/1,
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
  batch = [] :: [#span{}],
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

%% @doc Behaviour callbacks for exporters
behaviour_info(callbacks) ->
  [
    {init, 1},        %% init(Config) -> {ok, State} | {error, Reason}
    {export, 2},      %% export(Spans, State) -> {ok, NewState} | {error, Reason, NewState}
    {shutdown, 1},    %% shutdown(State) -> ok
    {force_flush, 1}  %% force_flush(State) -> {ok, NewState}
  ];
behaviour_info(_) ->
  undefined.

%% ============================================================================
%% API
%% ============================================================================

%% @doc Starts the exporter manager.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Registers an exporter.
-spec register(#{module := module(), config => map()}) -> ok | {error, term()}.
register(#{module := Module} = Exporter) ->
  Config = maps:get(config, Exporter, #{}),
  gen_server:call(?MODULE, {register, Module, Config}).

%% @doc Unregisters an exporter.
-spec unregister(module()) -> ok.
unregister(Module) ->
  gen_server:call(?MODULE, {unregister, Module}).

%% @doc Lists all registered exporters.
-spec list() -> [module()].
list() ->
  gen_server:call(?MODULE, list).

%% @doc Exports a single span (adds to batch).
-spec export_span(#span{}) -> ok.
export_span(Span) ->
  gen_server:cast(?MODULE, {export_span, Span}).

%% @doc Exports multiple spans immediately.
-spec export_spans([#span{}]) -> ok.
export_spans(Spans) ->
  gen_server:cast(?MODULE, {export_spans, Spans}).

%% @doc Forces a flush of all pending spans.
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
  %% Register as the default span exporter
  instrument_tracer:register_exporter(fun(Span) ->
    export_span(Span)
  end),
  {ok, #state{}}.

handle_call({register, Module, Config}, _From, State) ->
  case Module:init(Config) of
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
    catch M:shutdown(S)
  end, Removed),
  {reply, ok, State#state{exporters = Remaining}};

handle_call(list, _From, State) ->
  Modules = [M || #{module := M} <- State#state.exporters],
  {reply, Modules, State};

handle_call(flush, _From, State) ->
  State2 = do_flush(State),
  {reply, ok, State2};

handle_call(shutdown, _From, State) ->
  State2 = do_flush(State),
  lists:foreach(fun(#{module := M, state := S}) ->
    catch M:shutdown(S)
  end, State2#state.exporters),
  {reply, ok, State2#state{exporters = []}};

handle_call(_Request, _From, State) ->
  {reply, {error, unknown_request}, State}.

handle_cast({export_span, Span}, State) ->
  NewBatch = [Span | State#state.batch],
  State2 = maybe_start_timer(State#state{batch = NewBatch}),
  State3 = maybe_flush_batch(State2),
  {noreply, State3};

handle_cast({export_spans, Spans}, State) ->
  NewBatch = Spans ++ State#state.batch,
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
    catch M:shutdown(S)
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
    case catch M:export(Batch, S) of
      {ok, NewState} ->
        Exporter#{state => NewState};
      {error, _Reason, NewState} ->
        Exporter#{state => NewState};
      _ ->
        Exporter
    end
  end, Exporters),
  cancel_timer(State#state{batch = [], exporters = NewExporters}).

cancel_timer(#state{timer_ref = undefined} = State) ->
  State;
cancel_timer(#state{timer_ref = Ref} = State) ->
  erlang:cancel_timer(Ref),
  State#state{timer_ref = undefined}.
