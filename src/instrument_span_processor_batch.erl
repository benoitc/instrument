%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Batch span processor that queues spans and exports in batches.
%%
%% This processor collects spans and exports them in batches, providing
%% better performance than the simple processor in production.
%%
%% == Configuration ==
%% - `exporter': Exporter module (required)
%% - `exporter_config': Configuration for the exporter (default: #{})
%% - `max_queue_size': Maximum number of spans in queue (default: 2048)
%% - `max_export_batch_size': Maximum spans per export (default: 512)
%% - `schedule_delay_millis': Delay between exports in ms (default: 5000)
%% - `export_timeout_millis': Export timeout in ms (default: 30000)
%%
%% == Example ==
%% ```
%% instrument_span_processor:register(instrument_span_processor_batch, #{
%%   exporter => instrument_exporter_otlp,
%%   exporter_config => #{endpoint => "http://localhost:4318"},
%%   max_queue_size => 4096,
%%   schedule_delay_millis => 1000
%% }).
%% '''
-module(instrument_span_processor_batch).
-author("benoitc").

-behaviour(gen_server).
-behaviour(instrument_span_processor).

-include("instrument_otel.hrl").

%% API
-export([
  start_link/1
]).

%% Processor callbacks
-export([
  init/1,
  on_start/2,
  on_end/1,
  shutdown/0,
  shutdown/1,
  force_flush/0,
  force_flush/1
]).

%% gen_server callbacks
-export([
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3
]).

-define(DEFAULT_MAX_QUEUE_SIZE, 2048).
-define(DEFAULT_MAX_EXPORT_BATCH_SIZE, 512).
-define(DEFAULT_SCHEDULE_DELAY_MILLIS, 5000).
-define(DEFAULT_EXPORT_TIMEOUT_MILLIS, 30000).

-record(state, {
  exporter :: module(),
  exporter_state :: term(),
  max_queue_size :: pos_integer(),
  max_export_batch_size :: pos_integer(),
  schedule_delay :: pos_integer(),
  export_timeout :: pos_integer(),
  queue = [] :: [#span{}],
  queue_size = 0 :: non_neg_integer(),
  timer_ref :: reference() | undefined,
  dropped_spans = 0 :: non_neg_integer()
}).

%% ============================================================================
%% API
%% ============================================================================

%% @doc Starts the batch processor as a gen_server.
-spec start_link(map()) -> {ok, pid()} | ignore | {error, term()}.
start_link(Config) ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, Config, []).

%% ============================================================================
%% Processor Callbacks
%% ============================================================================

%% @doc Initializes the batch processor.
-spec init(map()) -> {ok, term()} | {error, term()}.
init(Config) ->
  Exporter = maps:get(exporter, Config),
  ExporterConfig = maps:get(exporter_config, Config, #{}),
  MaxQueueSize = maps:get(max_queue_size, Config, ?DEFAULT_MAX_QUEUE_SIZE),
  MaxExportBatchSize = maps:get(max_export_batch_size, Config, ?DEFAULT_MAX_EXPORT_BATCH_SIZE),
  ScheduleDelay = maps:get(schedule_delay_millis, Config, ?DEFAULT_SCHEDULE_DELAY_MILLIS),
  ExportTimeout = maps:get(export_timeout_millis, Config, ?DEFAULT_EXPORT_TIMEOUT_MILLIS),

  case Exporter:init(ExporterConfig) of
    {ok, ExporterState} ->
      State = #state{
        exporter = Exporter,
        exporter_state = ExporterState,
        max_queue_size = MaxQueueSize,
        max_export_batch_size = MaxExportBatchSize,
        schedule_delay = ScheduleDelay,
        export_timeout = ExportTimeout
      },
      %% Store state for on_end callback access
      persistent_term:put({?MODULE, state}, State),
      %% Start export timer
      TimerRef = schedule_export(ScheduleDelay),
      {ok, State#state{timer_ref = TimerRef}};
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Called when a span starts. Returns the span unchanged.
-spec on_start(#span{}, #span_ctx{} | undefined) -> #span{}.
on_start(Span, _ParentCtx) ->
  Span.

%% @doc Called when a span ends. Queues the span for batch export.
-spec on_end(#span{}) -> ok.
on_end(#span{is_recording = false}) ->
  %% Don't export non-recording spans
  ok;
on_end(Span) ->
  gen_server:cast(?MODULE, {on_end, Span}).

%% @doc Shuts down the processor.
-spec shutdown() -> ok.
shutdown() ->
  gen_server:call(?MODULE, shutdown).

%% @doc Shuts down the processor with state.
-spec shutdown(#state{}) -> ok.
shutdown(#state{exporter = Exporter, exporter_state = ExporterState}) ->
  catch Exporter:shutdown(ExporterState),
  ok.

%% @doc Forces an immediate export of all queued spans.
-spec force_flush() -> ok.
force_flush() ->
  gen_server:call(?MODULE, force_flush).

%% @doc Forces an immediate export with state.
-spec force_flush(#state{}) -> ok.
force_flush(_State) ->
  force_flush().

%% ============================================================================
%% gen_server callbacks
%% ============================================================================

handle_call(shutdown, _From, State) ->
  #state{
    exporter = Exporter,
    exporter_state = ExporterState,
    queue = Queue,
    timer_ref = TimerRef
  } = State,
  %% Cancel timer
  cancel_timer(TimerRef),
  %% Export remaining spans
  export_batch(Queue, Exporter, ExporterState),
  %% Shutdown exporter
  catch Exporter:shutdown(ExporterState),
  %% Clean up persistent_term
  persistent_term:erase({?MODULE, state}),
  {reply, ok, State#state{queue = [], queue_size = 0}};

handle_call(force_flush, _From, State) ->
  #state{
    exporter = Exporter,
    exporter_state = ExporterState,
    queue = Queue
  } = State,
  export_batch(Queue, Exporter, ExporterState),
  {reply, ok, State#state{queue = [], queue_size = 0}};

handle_call(_Request, _From, State) ->
  {reply, ok, State}.

handle_cast({on_end, Span}, State) ->
  #state{
    max_queue_size = MaxQueueSize,
    max_export_batch_size = MaxExportBatchSize,
    exporter = Exporter,
    exporter_state = ExporterState,
    queue = Queue,
    queue_size = QueueSize,
    dropped_spans = Dropped
  } = State,

  %% Check if queue is full
  case QueueSize >= MaxQueueSize of
    true ->
      %% Drop the span
      {noreply, State#state{dropped_spans = Dropped + 1}};
    false ->
      NewQueue = [Span | Queue],
      NewQueueSize = QueueSize + 1,
      %% Check if we should export immediately
      case NewQueueSize >= MaxExportBatchSize of
        true ->
          export_batch(NewQueue, Exporter, ExporterState),
          {noreply, State#state{queue = [], queue_size = 0}};
        false ->
          {noreply, State#state{queue = NewQueue, queue_size = NewQueueSize}}
      end
  end;

handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info(export, State) ->
  #state{
    exporter = Exporter,
    exporter_state = ExporterState,
    queue = Queue,
    schedule_delay = ScheduleDelay
  } = State,
  %% Export current batch
  export_batch(Queue, Exporter, ExporterState),
  %% Schedule next export
  TimerRef = schedule_export(ScheduleDelay),
  {noreply, State#state{queue = [], queue_size = 0, timer_ref = TimerRef}};

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, State) ->
  #state{
    exporter = Exporter,
    exporter_state = ExporterState,
    queue = Queue,
    timer_ref = TimerRef
  } = State,
  cancel_timer(TimerRef),
  export_batch(Queue, Exporter, ExporterState),
  catch Exporter:shutdown(ExporterState),
  persistent_term:erase({?MODULE, state}),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% ============================================================================
%% Internal Functions
%% ============================================================================

schedule_export(Delay) ->
  erlang:send_after(Delay, self(), export).

cancel_timer(undefined) ->
  ok;
cancel_timer(Ref) ->
  erlang:cancel_timer(Ref).

export_batch([], _Exporter, _ExporterState) ->
  ok;
export_batch(Spans, Exporter, ExporterState) ->
  %% Reverse to maintain order
  OrderedSpans = lists:reverse(Spans),
  try
    Exporter:export(OrderedSpans, ExporterState)
  catch
    _:_ -> ok
  end.
