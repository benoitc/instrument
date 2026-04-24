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

%% Tracks one in-flight export spawned from the gen_server loop. Keeping
%% the export off the main loop lets concurrent callers (force_flush,
%% on_end, timer) continue to make progress while the network call is
%% outstanding.
-type inflight() :: #{pid := pid(),
                      monitor := reference(),
                      ref := reference(),
                      spans := [#span{}],
                      kill_timer := reference(),
                      pending_froms := [gen_server:from()]}.

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
  max_batch_retries = ?DEFAULT_MAX_BATCH_RETRIES :: non_neg_integer(),
  %% When an async export is in flight the gen_server loop remains free to
  %% service span_end casts and new force_flush calls; their From tags are
  %% queued in `pending_froms' and replied to once the worker finishes.
  export_inflight = undefined :: undefined | inflight()
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
  %% Shutdown is synchronous: wait for any in-flight export, then drain the
  %% queue one last time. Retryable failures are not re-queued since we are
  %% going away.
  State1 = drain_inflight(State),
  #state{
    exporter = Exporter,
    exporter_state = ExporterState,
    queue = Queue,
    retry_spans = RetrySpans,
    timer_ref = TimerRef,
    export_timeout = ExportTimeout
  } = State1,
  cancel_timer(TimerRef),
  Combined = RetrySpans ++ Queue,
  {_Outcome, NewExporterState} =
    export_batch_sync(Combined, Exporter, ExporterState, ExportTimeout),
  try
    Exporter:shutdown(NewExporterState)
  catch
    Class:Reason:Stack ->
      logger:debug("Exporter shutdown failed: ~p:~p~n~p", [Class, Reason, Stack])
  end,
  {reply, ok, State1#state{queue = [], queue_size = 0,
                           retry_spans = [], retry_attempts = 0,
                           exporter_state = NewExporterState}};

%% force_flush returns without blocking the gen_server loop: the From tag is
%% queued and replied to when the in-flight export completes.
handle_call(force_flush, From, State) ->
  case State#state.export_inflight of
    undefined ->
      case has_pending_spans(State) of
        false -> {reply, ok, State};
        true -> {noreply, start_async_export([From], State)}
      end;
    Inflight ->
      Pending = maps:get(pending_froms, Inflight),
      NewInflight = Inflight#{pending_froms := [From | Pending]},
      {noreply, State#state{export_inflight = NewInflight}}
  end;

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
      case NewQueueSize >= MaxExportBatchSize andalso
           State1#state.export_inflight =:= undefined of
        true -> {noreply, start_async_export([], State1)};
        false -> {noreply, State1}
      end
  end;

handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info(export, State) ->
  %% Scheduled tick: if nothing is in flight and there are spans to send,
  %% start an async export. Otherwise skip this cycle.
  State1 = case State#state.export_inflight of
             undefined ->
               case has_pending_spans(State) of
                 true -> start_async_export([], State);
                 false -> State
               end;
             _ -> State
           end,
  TimerRef = schedule_export(State1#state.schedule_delay),
  {noreply, State1#state{timer_ref = TimerRef}};

handle_info({export_done, Ref, {Outcome, NewExporterState}}, State) ->
  case State#state.export_inflight of
    #{ref := Ref} = Inflight ->
      {noreply, finalize_export(Outcome, NewExporterState, Inflight, State)};
    _ ->
      %% Stale completion message from a killed worker. Drop it.
      {noreply, State}
  end;

handle_info({export_kill, Ref}, State) ->
  case State#state.export_inflight of
    #{ref := Ref} = Inflight ->
      #{pid := Pid, monitor := MonRef} = Inflight,
      erlang:demonitor(MonRef, [flush]),
      exit(Pid, kill),
      drain_ref_messages(Ref),
      {noreply, finalize_export(permanent, State#state.exporter_state,
                                Inflight, State)};
    _ ->
      {noreply, State}
  end;

handle_info({'DOWN', MonRef, process, _Pid, _Reason}, State) ->
  case State#state.export_inflight of
    #{monitor := MonRef, ref := Ref} = Inflight ->
      drain_ref_messages(Ref),
      {noreply, finalize_export(permanent, State#state.exporter_state,
                                Inflight, State)};
    _ ->
      {noreply, State}
  end;

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, State) ->
  State1 = drain_inflight(State),
  #state{
    exporter = Exporter,
    exporter_state = ExporterState,
    queue = Queue,
    retry_spans = RetrySpans,
    timer_ref = TimerRef,
    export_timeout = ExportTimeout
  } = State1,
  cancel_timer(TimerRef),
  Combined = RetrySpans ++ Queue,
  {_Outcome, NewExporterState} =
    export_batch_sync(Combined, Exporter, ExporterState, ExportTimeout),
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

cancel_timer(undefined) ->
  ok;
cancel_timer(Ref) ->
  erlang:cancel_timer(Ref).

has_pending_spans(#state{queue = [], retry_spans = []}) -> false;
has_pending_spans(_) -> true.

%% Spawn an export worker. The gen_server loop stays responsive while the
%% worker runs; the outcome comes back as {export_done, Ref, _} and a kill
%% timer bounds the worst-case runtime.
start_async_export(Froms, State) ->
  #state{
    exporter = Exporter,
    exporter_state = ExporterState,
    queue = Queue,
    retry_spans = RetrySpans,
    export_timeout = ExportTimeout
  } = State,
  Combined = RetrySpans ++ Queue,
  Parent = self(),
  Ref = make_ref(),
  {Pid, MonRef} = erlang:spawn_monitor(fun() ->
    Result = export_batch(Combined, Exporter, ExporterState),
    Parent ! {export_done, Ref, Result}
  end),
  KillTimer = erlang:send_after(ExportTimeout, self(), {export_kill, Ref}),
  Inflight = #{pid => Pid, monitor => MonRef, ref => Ref,
               spans => Combined, kill_timer => KillTimer,
               pending_froms => Froms},
  State#state{queue = [], queue_size = 0, export_inflight = Inflight}.

%% Apply the export outcome, reply to any queued flush callers, and kick off
%% another export if new spans arrived during the in-flight one.
finalize_export(Outcome, NewExporterState, Inflight, State) ->
  #{spans := Spans,
    pending_froms := Froms,
    kill_timer := KillTimer,
    monitor := MonRef} = Inflight,
  cancel_timer(KillTimer),
  erlang:demonitor(MonRef, [flush]),
  lists:foreach(fun(F) -> gen_server:reply(F, ok) end, Froms),
  #state{max_batch_retries = MaxBatchRetries,
         retry_attempts = RetryAttempts,
         dropped_spans = Dropped} = State,
  Base = State#state{exporter_state = NewExporterState,
                     export_inflight = undefined},
  NewState = case Outcome of
               Ok when Ok =:= ok; Ok =:= empty ->
                 Base#state{retry_spans = [], retry_attempts = 0};
               permanent ->
                 Base#state{retry_spans = [], retry_attempts = 0,
                            dropped_spans = Dropped + length(Spans)};
               retryable when RetryAttempts + 1 >= MaxBatchRetries ->
                 Base#state{retry_spans = [], retry_attempts = 0,
                            dropped_spans = Dropped + length(Spans)};
               retryable ->
                 Base#state{retry_spans = Spans,
                            retry_attempts = RetryAttempts + 1}
             end,
  case has_pending_spans(NewState) of
    true -> start_async_export([], NewState);
    false -> NewState
  end.

%% Synchronously wait for any in-flight export to complete. Used by shutdown
%% and terminate where we cannot return control to the main loop.
drain_inflight(#state{export_inflight = undefined} = State) ->
  State;
drain_inflight(#state{export_inflight = Inflight} = State) ->
  #{ref := Ref, monitor := MonRef, kill_timer := KillTimer,
    pid := Pid, pending_froms := Froms, spans := Spans} = Inflight,
  ExportTimeout = State#state.export_timeout,
  Result = receive
             {export_done, Ref, R} ->
               R;
             {'DOWN', MonRef, process, _, _} ->
               {permanent, State#state.exporter_state}
           after ExportTimeout ->
             exit(Pid, kill),
             {permanent, State#state.exporter_state}
           end,
  cancel_timer(KillTimer),
  erlang:demonitor(MonRef, [flush]),
  drain_ref_messages(Ref),
  lists:foreach(fun(F) -> gen_server:reply(F, ok) end, Froms),
  {_Outcome, NewExporterState} = Result,
  _ = Spans,
  State#state{export_inflight = undefined,
              exporter_state = NewExporterState}.

%% Synchronous one-shot export used only by shutdown / terminate.
export_batch_sync(Spans, Exporter, ExporterState, Timeout) ->
  Parent = self(),
  Ref = make_ref(),
  {Pid, MonRef} = erlang:spawn_monitor(fun() ->
    Result = export_batch(Spans, Exporter, ExporterState),
    Parent ! {Ref, Result}
  end),
  Outcome = receive
              {Ref, R} -> R;
              {'DOWN', MonRef, process, Pid, _Reason} -> {permanent, ExporterState}
            after Timeout ->
              exit(Pid, kill),
              {permanent, ExporterState}
            end,
  erlang:demonitor(MonRef, [flush]),
  drain_ref_messages(Ref),
  Outcome.

%% Returns {Outcome, NewExporterState} where Outcome is one of:
%%   ok           the batch was exported successfully
%%   empty        no spans were passed in
%%   retryable    transient failure, caller should retry the batch later
%%   permanent    non-retryable failure, caller should drop the batch
export_batch([], _Exporter, ExporterState) ->
  {empty, ExporterState};
export_batch(Spans, Exporter, ExporterState) ->
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

%% Drain any orphaned messages with the given ref and any residual DOWN
%% notifications, to prevent mailbox leaks.
drain_ref_messages(Ref) ->
  receive
    {Ref, _} -> drain_ref_messages(Ref);
    {export_done, Ref, _} -> drain_ref_messages(Ref)
  after 0 ->
    ok
  end.
