%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc OpenTelemetry Span Processor behavior and chain manager.
%%
%% Span processors are invoked at span start and end to perform
%% additional processing such as batching and exporting.
%%
%% == Built-in Processors ==
%% - `instrument_span_processor_simple' - Immediate export
%% - `instrument_span_processor_batch' - Batched export
%%
%% == Example Usage ==
%% ```
%% %% Register a processor
%% instrument_span_processor:register(instrument_span_processor_batch, #{
%%   exporter => instrument_exporter_console,
%%   max_queue_size => 2048
%% }).
%%
%% %% Unregister a processor
%% instrument_span_processor:unregister(instrument_span_processor_batch).
%% '''
%%
%% == Callback Restrictions ==
%% WARNING: Processor callbacks (on_start/2, on_end/1) execute within the
%% span processor gen_server. These callbacks must NOT call back into the
%% span processor system, as this will cause a deadlock.
%%
%% Avoid calling these functions from processor callbacks:
%% - `instrument_span_processor:register/2'
%% - `instrument_span_processor:unregister/1'
%% - `instrument_span_processor:list/0'
%% - `instrument_span_processor:shutdown/0'
%% - `instrument_span_processor:force_flush/0'
%%
%% Safe patterns for async work in callbacks:
%% - Spawn a new process for external calls
%% - Store in ETS for later batch processing
%% - Use async message passing
-module(instrument_span_processor).
-author("benoitc").

-behaviour(gen_server).

-include("instrument_otel.hrl").

%% API
-export([
  start_link/0,
  register/2,
  unregister/1,
  list/0,
  on_start/2,
  on_end/1,
  shutdown/0,
  force_flush/0
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

-define(SERVER, ?MODULE).

%% Behavior callbacks
%% WARNING: on_start and on_end execute in the span processor gen_server.
%% Do NOT call instrument_span_processor functions from these callbacks.
-callback on_start(Span :: #span{}, ParentCtx :: #span_ctx{} | undefined) -> #span{}.
-callback on_end(Span :: #span{}) -> ok.
-callback shutdown() -> ok.
-callback force_flush() -> ok.

-record(state, {
  processors = [] :: [{module(), term()}]
}).

%% ============================================================================
%% API
%% ============================================================================

%% @doc Starts the span processor manager.
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Registers a span processor with configuration.
-spec register(module(), map()) -> ok | {error, term()}.
register(ProcessorModule, Config) when is_atom(ProcessorModule), is_map(Config) ->
  gen_server:call(?SERVER, {register, ProcessorModule, Config}).

%% @doc Unregisters a span processor.
-spec unregister(module()) -> ok.
unregister(ProcessorModule) when is_atom(ProcessorModule) ->
  %% Use a long timeout to accommodate export_timeout_millis
  gen_server:call(?SERVER, {unregister, ProcessorModule}, 60000).

%% @doc Lists all registered processors.
-spec list() -> [module()].
list() ->
  gen_server:call(?SERVER, list).

%% @doc Called when a span starts. Returns potentially modified span.
-spec on_start(#span{}, #span_ctx{} | undefined) -> #span{}.
on_start(Span, ParentCtx) ->
  gen_server:call(?SERVER, {on_start, Span, ParentCtx}).

%% @doc Called when a span ends.
-spec on_end(#span{}) -> ok.
on_end(Span) ->
  gen_server:cast(?SERVER, {on_end, Span}).

%% @doc Shuts down all processors.
-spec shutdown() -> ok.
shutdown() ->
  gen_server:call(?SERVER, shutdown).

%% @doc Forces all processors to flush.
-spec force_flush() -> ok.
force_flush() ->
  gen_server:call(?SERVER, force_flush).

%% ============================================================================
%% gen_server callbacks
%% ============================================================================

init([]) ->
  {ok, #state{processors = []}}.

handle_call({register, ProcessorModule, Config}, _From, State) ->
  %% Batch processor needs its own gen_server for timers and async handling
  case ProcessorModule of
    instrument_span_processor_batch ->
      case start_batch_processor(Config) of
        {ok, _Pid} ->
          %% Store with a marker that it's externally managed
          NewProcessors = [{ProcessorModule, external} | State#state.processors],
          {reply, ok, State#state{processors = NewProcessors}};
        {error, Reason} ->
          {reply, {error, Reason}, State}
      end;
    _ ->
      case ProcessorModule:init(Config) of
        {ok, ProcessorState} ->
          NewProcessors = [{ProcessorModule, ProcessorState} | State#state.processors],
          {reply, ok, State#state{processors = NewProcessors}};
        {error, Reason} ->
          {reply, {error, Reason}, State}
      end
  end;

handle_call({unregister, ProcessorModule}, _From, State) ->
  case lists:keyfind(ProcessorModule, 1, State#state.processors) of
    {ProcessorModule, external} ->
      %% Stop externally managed gen_server (batch processor)
      catch ProcessorModule:shutdown(),
      catch stop_batch_processor(),
      NewProcessors = lists:keydelete(ProcessorModule, 1, State#state.processors),
      {reply, ok, State#state{processors = NewProcessors}};
    {ProcessorModule, ProcessorState} ->
      catch ProcessorModule:shutdown(ProcessorState),
      NewProcessors = lists:keydelete(ProcessorModule, 1, State#state.processors),
      {reply, ok, State#state{processors = NewProcessors}};
    false ->
      {reply, ok, State}
  end;

handle_call(list, _From, State) ->
  Modules = [M || {M, _} <- State#state.processors],
  {reply, Modules, State};

handle_call({on_start, Span, ParentCtx}, _From, State) ->
  %% Chain through all processors
  FinalSpan = lists:foldl(
    fun({Module, _ProcessorState}, AccSpan) ->
      try
        Module:on_start(AccSpan, ParentCtx)
      catch
        Class:Reason:Stacktrace ->
          logger:warning("Span processor ~p on_start failed: ~p:~p",
                        [Module, Class, Reason],
                        #{error_logger => #{tag => warning_msg},
                          mfa => {Module, on_start, 2},
                          stacktrace => Stacktrace}),
          AccSpan
      end
    end,
    Span,
    State#state.processors
  ),
  {reply, FinalSpan, State};

handle_call(shutdown, _From, State) ->
  lists:foreach(
    fun({Module, external}) ->
      catch Module:shutdown(),
      catch stop_batch_processor();
    ({Module, ProcessorState}) ->
      catch Module:shutdown(ProcessorState)
    end,
    State#state.processors
  ),
  {reply, ok, State#state{processors = []}};

handle_call(force_flush, _From, State) ->
  lists:foreach(
    fun({Module, external}) ->
      catch Module:force_flush();
    ({Module, ProcessorState}) ->
      catch Module:force_flush(ProcessorState)
    end,
    State#state.processors
  ),
  {reply, ok, State};

handle_call(_Request, _From, State) ->
  {reply, ok, State}.

handle_cast({on_end, Span}, State) ->
  %% Notify all processors
  lists:foreach(
    fun({Module, _ProcessorState}) ->
      try
        Module:on_end(Span)
      catch
        Class:Reason:Stacktrace ->
          logger:warning("Span processor ~p on_end failed: ~p:~p",
                        [Module, Class, Reason],
                        #{error_logger => #{tag => warning_msg},
                          mfa => {Module, on_end, 1},
                          stacktrace => Stacktrace})
      end
    end,
    State#state.processors
  ),
  {noreply, State};

handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, State) ->
  %% Shutdown all processors
  lists:foreach(
    fun({Module, external}) ->
      catch Module:shutdown(),
      catch stop_batch_processor();
    ({Module, ProcessorState}) ->
      catch Module:shutdown(ProcessorState)
    end,
    State#state.processors
  ),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% ============================================================================
%% Internal Functions
%% ============================================================================

%% @private Start batch processor under the instrument supervisor
start_batch_processor(Config) ->
  %% Set shutdown timeout based on export_timeout_millis plus buffer
  ExportTimeout = maps:get(export_timeout_millis, Config, 30000),
  ShutdownTimeout = ExportTimeout + 5000,
  ChildSpec = #{
    id => instrument_span_processor_batch,
    start => {instrument_span_processor_batch, start_link, [Config]},
    restart => permanent,
    shutdown => ShutdownTimeout,
    type => worker,
    modules => [instrument_span_processor_batch]
  },
  supervisor:start_child(instrument_sup, ChildSpec).

%% @private Stop batch processor
stop_batch_processor() ->
  supervisor:terminate_child(instrument_sup, instrument_span_processor_batch),
  supervisor:delete_child(instrument_sup, instrument_span_processor_batch).
