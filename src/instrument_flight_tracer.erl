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
%% - Handles overflow by evicting oldest entries
-module(instrument_flight_tracer).
-author("benoitc").

-behaviour(gen_server).

%% API
-export([
  start_link/1
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

-record(state, {
  index :: non_neg_integer(),
  buffer = [] :: list(),
  buffer_count = 0 :: non_neg_integer()
}).

%% ============================================================================
%% API
%% ============================================================================

%% @doc Starts a flight tracer worker.
-spec start_link(non_neg_integer()) -> {ok, pid()} | ignore | {error, term()}.
start_link(Index) ->
  gen_server:start_link(?MODULE, [Index], []).

%% ============================================================================
%% gen_server callbacks
%% ============================================================================

init([Index]) ->
  %% Optimize for high message throughput
  process_flag(message_queue_data, off_heap),
  process_flag(priority, high),
  %% Schedule periodic flush
  erlang:send_after(?FLUSH_INTERVAL, self(), flush),
  {ok, #state{index = Index}}.

handle_call(_Request, _From, State) ->
  {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.

%% Receive trace events from NIF
%% Format: {trace, Tracee, TraceTag, TraceTerm, Opts, Label, Timestamp}
%% Opts is a map: #{extra => Extra, timestamp => TS, ...}
handle_info({trace, Tracee, TraceTag, TraceTerm, Opts, Label, Timestamp}, State) ->
  Event = format_event(TraceTag, Tracee, TraceTerm, Opts),
  Key = {Timestamp, erlang:unique_integer([monotonic])},
  NewBuffer = [{Key, Label, Event} | State#state.buffer],
  NewCount = State#state.buffer_count + 1,
  case NewCount >= ?BATCH_SIZE of
    true ->
      flush_buffer(NewBuffer),
      {noreply, State#state{buffer = [], buffer_count = 0}};
    false ->
      {noreply, State#state{buffer = NewBuffer, buffer_count = NewCount}}
  end;

%% Periodic flush to ensure events don't get stuck in buffer
handle_info(flush, State) ->
  NewState = case State#state.buffer of
    [] ->
      State;
    Buffer ->
      flush_buffer(Buffer),
      State#state{buffer = [], buffer_count = 0}
  end,
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

%% @private Format trace event for storage.
%% Opts is a map that may contain 'extra' field with additional data
format_event(send, Tracee, Msg, Opts) ->
  To = maps:get(extra, Opts, undefined),
  {send, Tracee, Msg, To};
format_event(send_to_non_existing_process, Tracee, Msg, Opts) ->
  To = maps:get(extra, Opts, undefined),
  {send_to_non_existing_process, Tracee, Msg, To};
format_event('receive', Tracee, Msg, _Opts) ->
  {'receive', Tracee, Msg};
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
  {TraceTag, Tracee, TraceTerm, Opts}.

%% @private Flush buffered events to ETS.
flush_buffer(Buffer) ->
  try
    ets:insert(?BUFFER_TABLE, Buffer)
  catch
    error:badarg ->
      %% Table might not exist or be read-only
      ok
  end.
