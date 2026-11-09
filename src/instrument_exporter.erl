%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Exporter management for spans and metrics.
%%
%% This module provides a registry for exporters and batch processing
%% of spans for efficient export.
%%
%% Spans are admitted by the ending process before they are sent here: once
%% `exporter_max_queue_size' spans (default 2048) are waiting, further spans
%% are dropped and counted in stats/0. Exports run in a separate process, one
%% at a time, so a slow or retrying exporter does not block this server. The
%% tracer only calls into this module while at least one exporter is
%% registered.
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
  code_change/3
]).

-include("instrument_otel.hrl").

-define(ADMISSION, '$instrument_exporter_admission').

-record(state, {
  batcher :: instrument_export_batcher:batcher(),
  hook_fun :: fun((#span{}) -> ok),
  hooked = false :: boolean()
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
    %% Optional: export_async() -> true runs exports in a separate process,
    %% so a slow exporter does not block the server. Only for exporters whose
    %% state is not tied to the process that called init (no raw files).
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

%% @doc Exports a single span (adds to batch). Dropped when the queue is
%% full.
-spec export_span(#span{}) -> ok.
export_span(Span) ->
  case instrument_admission:admit(?ADMISSION, 1) of
    true -> gen_server:cast(?MODULE, {export_spans, [Span], 1});
    false -> ok
  end.

%% @doc Exports multiple spans. Dropped when they do not fit in the queue.
-spec export_spans([#span{}]) -> ok.
export_spans([]) ->
  ok;
export_spans(Spans) ->
  N = length(Spans),
  case instrument_admission:admit(?ADMISSION, N) of
    true -> gen_server:cast(?MODULE, {export_spans, Spans, N});
    false -> ok
  end.

%% @doc Exports all pending spans and flushes the exporters.
-spec flush() -> ok.
flush() ->
  gen_server:call(?MODULE, flush, export_timeout() + 5000).

%% @doc Exports pending spans and shuts down all exporters.
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
  HookFun = fun(Span) -> export_span(Span) end,
  Batcher = instrument_export_batcher:new(#{
    admission => ?ADMISSION,
    callbacks => callbacks(),
    max_queue => max_queue(),
    export_timeout => export_timeout()
  }),
  %% After a restart, initialize the exporters registered before the crash.
  B = lists:foldl(fun({Module, Config}, Acc) ->
        case instrument_lib:safe_apply(Module, init, [Config], error) of
          {ok, S} ->
            instrument_export_batcher:add_exporter(
              #{module => Module, config => Config, state => S}, Acc);
          _ ->
            Acc
        end
      end, Batcher, instrument_registrations:list(span_exporter)),
  {ok, update_hook(#state{batcher = B, hook_fun = HookFun})}.

handle_call({register, Module, Config}, _From, #state{batcher = B} = State) ->
  case Module:init(Config) of
    {ok, ExporterState} ->
      Exporter = #{module => Module, config => Config, state => ExporterState},
      B1 = instrument_export_batcher:add_exporter(Exporter, B),
      ok = instrument_registrations:put(span_exporter, Module, Config),
      {reply, ok, update_hook(State#state{batcher = B1})};
    {error, Reason} ->
      {reply, {error, Reason}, State}
  end;

handle_call({unregister, Module}, _From, #state{batcher = B} = State) ->
  {Removed, B1} = instrument_export_batcher:remove_exporter(Module, B),
  lists:foreach(fun(#{module := M, state := S}) ->
    instrument_lib:safe_apply(M, shutdown, [S], ok)
  end, Removed),
  ok = instrument_registrations:delete(span_exporter, Module),
  {reply, ok, update_hook(State#state{batcher = B1})};

handle_call(list, _From, #state{batcher = B} = State) ->
  Modules = [M || #{module := M} <- instrument_export_batcher:exporters(B)],
  {reply, Modules, State};

handle_call(flush, From, #state{batcher = B} = State) ->
  {noreply, State#state{batcher = instrument_export_batcher:flush(From, B)}};

handle_call(shutdown, _From, #state{batcher = B} = State) ->
  B1 = instrument_export_batcher:shutdown_exporters(instrument_export_batcher:drain(B)),
  ok = instrument_registrations:clear(span_exporter),
  {reply, ok, update_hook(State#state{batcher = B1})};

handle_call(_Request, _From, State) ->
  {reply, {error, unknown_request}, State}.

handle_cast({export_spans, Spans, N}, #state{batcher = B} = State) ->
  {noreply, State#state{batcher = instrument_export_batcher:add(Spans, N, B)}};

handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info(Info, #state{batcher = B} = State) ->
  case instrument_export_batcher:handle_info(Info, B) of
    {ok, B1} -> {noreply, State#state{batcher = B1}};
    ignore -> {noreply, State}
  end.

terminate(_Reason, #state{batcher = B} = State) ->
  B1 = instrument_export_batcher:shutdown_exporters(instrument_export_batcher:drain(B)),
  _ = update_hook(State#state{batcher = B1}),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% ============================================================================
%% Internal functions
%% ============================================================================

%% The tracer calls export_span/1 only while at least one exporter is
%% registered, so an idle exporter costs nothing per span and does not
%% export spans a processor already handles.
update_hook(#state{batcher = B, hooked = Hooked, hook_fun = Hook} = State) ->
  case {instrument_export_batcher:exporters(B) =/= [], Hooked} of
    {true, false} ->
      instrument_tracer:register_exporter(Hook),
      State#state{hooked = true};
    {false, true} ->
      instrument_lib:safe_apply(instrument_tracer, unregister_exporter, [Hook], ok),
      State#state{hooked = false};
    _ ->
      State
  end.

callbacks() ->
  #{export => fun(M, Spans, S) ->
                case M:export(Spans, S) of
                  {ok, NewS} -> NewS;
                  {error, _Reason, NewS} -> NewS;
                  _ -> S
                end
              end,
    shutdown => fun(M, S) -> M:shutdown(S) end,
    force_flush => fun(M, S) ->
                     case M:force_flush(S) of
                       {ok, NewS} -> NewS;
                       _ -> S
                     end
                   end}.

max_queue() ->
  case application:get_env(instrument, exporter_max_queue_size) of
    {ok, N} when is_integer(N), N > 0 -> N;
    _ -> 2048
  end.

export_timeout() ->
  30000.
