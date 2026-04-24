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
-define(SHUTDOWN_TIMEOUT_MILLIS, 10000).
%% Max times a batch may be rescheduled after a retryable export failure
%% before it is dropped. The OTLP exporter itself also does bounded retry,
%% so across both layers a batch can see up to roughly
%% `(MaxRetries + 1) * (MaxBatchRetries + 1)' attempts.
-define(DEFAULT_MAX_BATCH_RETRIES, 3).

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
  dropped_spans = 0 :: non_neg_integer(),
  %% Spans from a retryable export that will be re-attempted on the next
  %% scheduled flush. `retry_attempts' counts consecutive retryable failures
  %% of this batch; at `max_batch_retries' it is dropped.
  retry_spans = [] :: [#span{}],
  retry_attempts = 0 :: non_neg_integer(),
  max_batch_retries = ?DEFAULT_MAX_BATCH_RETRIES :: non_neg_integer()
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
  MaxBatchRetries = maps:get(max_batch_retries, Config, ?DEFAULT_MAX_BATCH_RETRIES),

  case Exporter:init(ExporterConfig) of
    {ok, ExporterState} ->
      State = #state{
        exporter = Exporter,
        exporter_state = ExporterState,
        max_queue_size = MaxQueueSize,
        max_export_batch_size = MaxExportBatchSize,
        schedule_delay = ScheduleDelay,
        export_timeout = ExportTimeout,
        max_batch_retries = MaxBatchRetries
      },
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
  gen_server:call(?MODULE, shutdown, ?SHUTDOWN_TIMEOUT_MILLIS).

%% @doc Shuts down the processor with state.
-spec shutdown(#state{}) -> ok.
shutdown(#state{exporter = Exporter, exporter_state = ExporterState}) ->
  try
    Exporter:shutdown(ExporterState)
  catch
    Class:Reason:Stack ->
      logger:debug("Exporter shutdown failed: ~p:~p~n~p", [Class, Reason, Stack])
  end,
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
    retry_spans = RetrySpans,
    timer_ref = TimerRef,
    export_timeout = ExportTimeout
  } = State,
  %% Cancel timer
  cancel_timer(TimerRef),
  %% Export remaining spans with configured timeout. Shutdown is best-effort
  %% so retryable failures are not re-queued.
  Combined = RetrySpans ++ Queue,
  {_Outcome, NewExporterState} =
    export_batch_with_timeout(Combined, Exporter, ExporterState, ExportTimeout),
  %% Shutdown exporter
  try
    Exporter:shutdown(NewExporterState)
  catch
    Class:Reason:Stack ->
      logger:debug("Exporter shutdown failed: ~p:~p~n~p", [Class, Reason, Stack])
  end,
  {reply, ok, State#state{queue = [], queue_size = 0,
                          retry_spans = [], retry_attempts = 0,
                          exporter_state = NewExporterState}};

handle_call(force_flush, _From, State) ->
  {reply, ok, do_scheduled_export(State)};

handle_call(_Request, _From, State) ->
  {reply, ok, State}.

handle_cast({on_end, Span}, State) ->
  #state{
    max_queue_size = MaxQueueSize,
    max_export_batch_size = MaxExportBatchSize,
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
      State1 = State#state{queue = NewQueue, queue_size = NewQueueSize},
      %% Check if we should export immediately
      case NewQueueSize >= MaxExportBatchSize of
        true -> {noreply, do_scheduled_export(State1)};
        false -> {noreply, State1}
      end
  end;

handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info(export, State) ->
  State1 = do_scheduled_export(State),
  TimerRef = schedule_export(State1#state.schedule_delay),
  {noreply, State1#state{timer_ref = TimerRef}};

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, State) ->
  #state{
    exporter = Exporter,
    exporter_state = ExporterState,
    queue = Queue,
    retry_spans = RetrySpans,
    timer_ref = TimerRef,
    export_timeout = ExportTimeout
  } = State,
  cancel_timer(TimerRef),
  %% Use configured export timeout for shutdown
  Combined = RetrySpans ++ Queue,
  {_Outcome, NewExporterState} =
    export_batch_with_timeout(Combined, Exporter, ExporterState, ExportTimeout),
  try
    Exporter:shutdown(NewExporterState)
  catch
    Class:Reason:Stack ->
      logger:debug("Exporter shutdown failed in terminate: ~p:~p~n~p", [Class, Reason, Stack])
  end,
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% ============================================================================
%% Internal Functions
%% ============================================================================

schedule_export(Delay) ->
  erlang:send_after(Delay, self(), export).

%% Drives an export cycle. Prepends any in-flight retry batch to the current
%% queue, exports with a timeout, then classifies the outcome:
%%   ok / empty / permanent -> clear the queue
%%   retryable + attempts < max_batch_retries -> keep the spans for next cycle
%%   retryable + attempts hit the cap -> drop and count them as dropped_spans
do_scheduled_export(State) ->
  #state{
    exporter = Exporter,
    exporter_state = ExporterState,
    queue = Queue,
    retry_spans = RetrySpans,
    retry_attempts = RetryAttempts,
    max_batch_retries = MaxBatchRetries,
    export_timeout = ExportTimeout,
    dropped_spans = Dropped
  } = State,
  %% The queue is LIFO (head is newest). Retry spans are already in send-order
  %% after the first export_batch reversed them, so prepend them to the head
  %% of the queue to preserve overall order.
  Combined = RetrySpans ++ Queue,
  case Combined of
    [] -> State;
    _ ->
      {Outcome, NewExporterState} =
        export_batch_with_timeout(Combined, Exporter, ExporterState, ExportTimeout),
      Base = State#state{queue = [], queue_size = 0,
                         exporter_state = NewExporterState},
      case Outcome of
        Ok when Ok =:= ok; Ok =:= empty; Ok =:= permanent ->
          PermDropped = case Outcome of
                          permanent -> Dropped + length(Combined);
                          _ -> Dropped
                        end,
          Base#state{retry_spans = [], retry_attempts = 0,
                     dropped_spans = PermDropped};
        retryable when RetryAttempts + 1 >= MaxBatchRetries ->
          Base#state{retry_spans = [], retry_attempts = 0,
                     dropped_spans = Dropped + length(Combined)};
        retryable ->
          Base#state{retry_spans = Combined,
                     retry_attempts = RetryAttempts + 1}
      end
  end.

cancel_timer(undefined) ->
  ok;
cancel_timer(Ref) ->
  erlang:cancel_timer(Ref).

%% Returns {Outcome, NewExporterState} where Outcome is one of:
%%   ok           the batch was exported successfully
%%   empty        no spans were passed in
%%   retryable    transient failure, caller should retry the batch later
%%   permanent    non-retryable failure, caller should drop the batch
export_batch([], _Exporter, ExporterState) ->
  {empty, ExporterState};
export_batch(Spans, Exporter, ExporterState) ->
  %% Reverse to maintain order
  OrderedSpans = lists:reverse(Spans),
  try
    case Exporter:export(OrderedSpans, ExporterState) of
      {ok, NewState} -> {ok, NewState};
      {error, retryable, NewState} -> {retryable, NewState};
      {error, permanent, NewState} -> {permanent, NewState};
      {error, _Reason, NewState} -> {permanent, NewState};
      _ -> {permanent, ExporterState}
    end
  catch
    _:_ -> {permanent, ExporterState}
  end.

export_batch_with_timeout(Spans, Exporter, ExporterState, Timeout) ->
  Parent = self(),
  Ref = make_ref(),
  {Pid, MonRef} = erlang:spawn_monitor(fun() ->
    Result = export_batch(Spans, Exporter, ExporterState),
    Parent ! {Ref, Result}
  end),
  receive
    {Ref, Result} ->
      erlang:demonitor(MonRef, [flush]),
      Result;
    {'DOWN', MonRef, process, Pid, _Reason} ->
      %% Drain any late message from the worker
      drain_ref_message(Ref),
      {permanent, ExporterState}
  after Timeout ->
    erlang:demonitor(MonRef, [flush]),
    exit(Pid, kill),
    %% Drain any late message from the worker that may have arrived just before/during kill
    drain_ref_message(Ref),
    {permanent, ExporterState}
  end.

%% Drain any orphaned message with the given ref to prevent mailbox leaks
drain_ref_message(Ref) ->
  receive
    {Ref, _} -> ok
  after 0 ->
    ok
  end.
