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
  on_start_inline/2,
  on_end_inline/1,
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
-define(PROCESSORS_CACHE_KEY, '$instrument_processors').

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
%% This is the legacy path; the tracer hot path goes through
%% {@link on_start_inline/2} via the persistent_term cache and never reaches
%% this gen_server. The 5 s timeout is a safety net for processors whose
%% on_start callback hangs.
-spec on_start(#span{}, #span_ctx{} | undefined) -> #span{}.
on_start(Span, ParentCtx) ->
  try
    gen_server:call(?SERVER, {on_start, Span, ParentCtx}, 5000)
  catch
    exit:{timeout, _} -> Span;
    exit:{noproc, _}  -> Span
  end.

%% @doc Called when a span ends.
-spec on_end(#span{}) -> ok.
on_end(Span) ->
  gen_server:cast(?SERVER, {on_end, Span}).

%% @doc Called when a span starts - inline version without gen_server hop.
%% Uses cached processor list from persistent_term for O(1) access.
-spec on_start_inline(#span{}, #span_ctx{} | undefined) -> #span{}.
on_start_inline(Span, ParentCtx) ->
  Processors = persistent_term:get(?PROCESSORS_CACHE_KEY, []),
  lists:foldl(
    fun({Module, _PState}, AccSpan) ->
      try
        Module:on_start(AccSpan, ParentCtx)
      catch
        _:_ -> AccSpan
      end
    end,
    Span,
    Processors).

%% @doc Called when a span ends - inline version without gen_server hop.
%% Uses cached processor list from persistent_term for O(1) access.
-spec on_end_inline(#span{}) -> ok.
on_end_inline(Span) ->
  Processors = persistent_term:get(?PROCESSORS_CACHE_KEY, []),
  lists:foreach(
    fun({Module, _PState}) ->
      try
        Module:on_end(Span)
      catch
        _:_ -> ok
      end
    end,
    Processors),
  ok.

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
  %% Initialize processor cache (empty list initially)
  persistent_term:put(?PROCESSORS_CACHE_KEY, []),
  {ok, #state{processors = []}}.

handle_call({register, ProcessorModule, Config}, _From, State) ->
  %% Batch processor needs its own gen_server for timers and async handling
  case ProcessorModule of
    instrument_span_processor_batch ->
      case start_batch_processor(Config) of
        {ok, _Pid} ->
          %% Store with a marker that it's externally managed
          NewProcessors = [{ProcessorModule, external} | State#state.processors],
          NewState = State#state{processors = NewProcessors},
          refresh_processor_cache(NewState),
          {reply, ok, NewState};
        {error, Reason} ->
          {reply, {error, Reason}, State}
      end;
    _ ->
      case ProcessorModule:init(Config) of
        {ok, ProcessorState} ->
          NewProcessors = [{ProcessorModule, ProcessorState} | State#state.processors],
          NewState = State#state{processors = NewProcessors},
          refresh_processor_cache(NewState),
          {reply, ok, NewState};
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
      NewState = State#state{processors = NewProcessors},
      refresh_processor_cache(NewState),
      {reply, ok, NewState};
    {ProcessorModule, ProcessorState} ->
      catch ProcessorModule:shutdown(ProcessorState),
      NewProcessors = lists:keydelete(ProcessorModule, 1, State#state.processors),
      NewState = State#state{processors = NewProcessors},
      refresh_processor_cache(NewState),
      {reply, ok, NewState};
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

%% @private Refresh the processor cache in persistent_term.
refresh_processor_cache(#state{processors = Processors}) ->
  persistent_term:put(?PROCESSORS_CACHE_KEY, Processors).
