%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Worker process for receiving and storing trace events.
%%
%% This module implements a worker that receives trace events from the
%% tracer NIF and inserts them into the shared ETS buffer. Each worker
%% handles a subset of tracees based on pid hashing, distributing the
%% load across multiple processes.
%%
%% Features:
%% - Uses off_heap message queue to reduce GC pressure
%% - Batch inserts events to minimize ETS overhead
%% - Acknowledges handled events to the NIF queue counters, which bound how
%%   many events can wait in this worker's mailbox
%% - Truncates message payloads larger than `flight_recorder_max_payload_bytes'
%% - Asks the recorder to evict as soon as the buffer is over its limit
-module(instrument_flight_tracer).
-author("benoitc").

-behaviour(gen_server).

%% API
-export([
  start_link/2,
  truncate/2,
  max_payload/0
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

-define(BUFFER_TABLE, instrument_flight_buffer).
-define(BATCH_SIZE, 100).
-define(FLUSH_INTERVAL, 50).
-define(DEFAULT_MAX_PAYLOAD, 1024).

-record(state, {
  index :: non_neg_integer(),
  counters :: reference() | undefined,
  max_payload :: non_neg_integer(),
  buffer = [] :: list(),
  buffer_count = 0 :: non_neg_integer(),
  unacked = 0 :: non_neg_integer()
}).

%% ============================================================================
%% API
%% ============================================================================

%% @doc Starts flight tracer worker `Index', registered under
%% instrument_tracer_pool:worker_name/1.
-spec start_link(non_neg_integer(), reference() | undefined) ->
  {ok, pid()} | ignore | {error, term()}.
start_link(Index, Counters) ->
  gen_server:start_link({local, instrument_tracer_pool:worker_name(Index)},
                        ?MODULE, [Index, Counters], []).

%% @doc Payload size limit in bytes (`flight_recorder_max_payload_bytes',
%% default 1024, 0 keeps only the size).
-spec max_payload() -> non_neg_integer().
max_payload() ->
  instrument_lib:bounded_env(flight_recorder_max_payload_bytes,
                             ?DEFAULT_MAX_PAYLOAD, 0, 1 bsl 30).

%% @doc Returns `Term', or `{truncated, Size}' when its external size is over
%% `Max' bytes.
-spec truncate(term(), non_neg_integer()) -> term().
truncate({truncated, Size} = Term, _Max) when is_integer(Size) ->
  %% Already truncated by the tracer NIF before it was queued.
  Term;
truncate(Term, Max) when is_integer(Term); is_atom(Term); is_pid(Term);
                         is_reference(Term); is_port(Term) ->
  case Max of
    0 -> {truncated, erlang:external_size(Term)};
    _ -> Term
  end;
truncate(Term, Max) ->
  case erlang:external_size(Term) of
    Size when Size > Max -> {truncated, Size};
    _ -> Term
  end.

%% ============================================================================
%% gen_server callbacks
%% ============================================================================

init([Index, Counters]) ->
  %% Optimize for high message throughput
  process_flag(message_queue_data, off_heap),
  process_flag(priority, high),
  %% Events queued to a previous incarnation of this worker are gone.
  reset_counter(Counters, Index),
  %% Schedule periodic flush
  erlang:send_after(?FLUSH_INTERVAL, self(), flush),
  {ok, #state{index = Index, counters = Counters, max_payload = max_payload()}}.

handle_call(_Request, _From, State) ->
  {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.

%% Receive trace events from NIF
%% Format: {trace, Tracee, TraceTag, TraceTerm, Opts, Label, Timestamp}
%% Opts is a map: #{extra => Extra, timestamp => TS, ...}
handle_info({trace, Tracee, TraceTag, TraceTerm, Opts, Label, Timestamp},
            #state{max_payload = Max} = State) ->
  Event = format_event(TraceTag, Tracee, TraceTerm, Opts, Max),
  Key = {Timestamp, erlang:unique_integer([monotonic])},
  NewBuffer = [{Key, Label, Event} | State#state.buffer],
  NewCount = State#state.buffer_count + 1,
  State1 = State#state{buffer = NewBuffer, buffer_count = NewCount,
                       unacked = State#state.unacked + 1},
  case NewCount >= ?BATCH_SIZE of
    true -> {noreply, flush(State1)};
    false -> {noreply, State1}
  end;

%% Periodic flush to ensure events don't get stuck in buffer
handle_info(flush, State) ->
  NewState = flush(State),
  erlang:send_after(?FLUSH_INTERVAL, self(), flush),
  {noreply, NewState};

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, State) ->
  %% Flush remaining events on shutdown
  case State#state.buffer of
    [] -> ok;
    Buffer -> flush_buffer(Buffer)
  end,
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% ============================================================================
%% Internal Functions
%% ============================================================================

%% @private Insert the batch, acknowledge handled events to the NIF counters
%% and ask the recorder to evict if the buffer is over its limit.
flush(#state{buffer = [], unacked = 0} = State) ->
  State;
flush(#state{buffer = Buffer, unacked = Unacked, counters = Counters,
             index = Index} = State) ->
  case Buffer of
    [] -> ok;
    _ ->
      flush_buffer(Buffer),
      instrument_flight_recorder:maybe_evict()
  end,
  ack(Counters, Index, Unacked),
  State#state{buffer = [], buffer_count = 0, unacked = 0}.

ack(undefined, _Index, _N) -> ok;
ack(_Counters, _Index, 0) -> ok;
ack(Counters, Index, N) ->
  instrument_lib:safe_apply(instrument_tracer_nif, ack, [Counters, Index, N], ok).

reset_counter(undefined, _Index) -> ok;
reset_counter(Counters, Index) ->
  instrument_lib:safe_apply(instrument_tracer_nif, reset_worker, [Counters, Index], ok).

%% @private Format trace event for storage. Message payloads and exit reasons
%% are truncated to `Max' bytes.
format_event(send, Tracee, Msg, Opts, Max) ->
  To = maps:get(extra, Opts, undefined),
  {send, Tracee, truncate(Msg, Max), To};
format_event(send_to_non_existing_process, Tracee, Msg, Opts, Max) ->
  To = maps:get(extra, Opts, undefined),
  {send_to_non_existing_process, Tracee, truncate(Msg, Max), To};
format_event('receive', Tracee, Msg, _Opts, Max) ->
  {'receive', Tracee, truncate(Msg, Max)};
format_event(exit, Tracee, Reason, _Opts, Max) ->
  {exit, Tracee, truncate(Reason, Max)};
format_event(Tag, Tracee, Term, Opts, _Max) ->
  format_event(Tag, Tracee, Term, Opts).

%% Opts is a map that may contain 'extra' field with additional data
format_event(spawn, Tracee, Pid, Opts) ->
  MFA = maps:get(extra, Opts, undefined),
  {spawn, Tracee, Pid, MFA};
format_event(spawned, Tracee, Pid, Opts) ->
  MFA = maps:get(extra, Opts, undefined),
  {spawned, Tracee, Pid, MFA};
format_event(exit, Tracee, Reason, _Opts) ->
  {exit, Tracee, Reason};
format_event(link, Tracee, Linked, _Opts) ->
  {link, Tracee, Linked};
format_event(unlink, Tracee, Unlinked, _Opts) ->
  {unlink, Tracee, Unlinked};
format_event(getting_linked, Tracee, Linker, _Opts) ->
  {getting_linked, Tracee, Linker};
format_event(getting_unlinked, Tracee, Unlinker, _Opts) ->
  {getting_unlinked, Tracee, Unlinker};
format_event(register, Tracee, Name, _Opts) ->
  {register, Tracee, Name};
format_event(unregister, Tracee, Name, _Opts) ->
  {unregister, Tracee, Name};
format_event(TraceTag, Tracee, TraceTerm, Opts) ->
  %% Generic fallback for other trace tags
  {TraceTag, Tracee, truncate(TraceTerm, max_payload()), Opts}.

%% @private Flush buffered events to ETS.
flush_buffer(Buffer) ->
  try
    ets:insert(?BUFFER_TABLE, Buffer)
  catch
    error:badarg ->
      %% Table might not exist or be read-only
      ok
  end.
