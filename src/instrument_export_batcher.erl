%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @private Batching and asynchronous export for the span and log exporter
%% servers.
%%
%% The owning gen_server keeps a batcher in its state and forwards items,
%% exporter registrations, flush calls and its info messages to it. Items are
%% admitted by the sender through instrument_admission, which bounds the
%% server's mailbox plus batch to `max_queue' items.
%%
%% Exporters that declare `export_async() -> true' run in a monitored worker
%% process, one export at a time, bounded by a kill timer, so a slow or
%% retrying network exporter never blocks the server loop. Other exporters
%% run in the server process as before, because they may hold resources tied
%% to the process that opened them (such as a raw file handle).
-module(instrument_export_batcher).

-export([
  new/1,
  add/3,
  add_exporter/2,
  remove_exporter/2,
  exporters/1,
  flush/2,
  handle_info/2,
  drain/1,
  shutdown_exporters/1
]).

-type exporter() :: #{module := module(), config := map(), state := term()}.

-type callbacks() :: #{
  %% Export Items with one exporter; returns the exporter's new state.
  export := fun((module(), [term()], term()) -> term()),
  shutdown := fun((module(), term()) -> term()),
  force_flush := fun((module(), term()) -> term())
}.

-record(batcher, {
  admission :: term(),
  callbacks :: callbacks(),
  exporters = [] :: [exporter()],
  batch = [] :: [term()],              %% newest first
  count = 0 :: non_neg_integer(),
  batch_size :: pos_integer(),
  batch_timeout :: pos_integer(),
  export_timeout :: pos_integer(),
  timer_ref :: reference() | undefined,
  inflight :: undefined | map(),
  waiting = [] :: [gen_server:from()]  %% flush callers for the next export
}).

-opaque batcher() :: #batcher{}.
-export_type([batcher/0, exporter/0]).

%% @doc Creates a batcher. Options: `admission' (counter key, required),
%% `callbacks' (required), `max_queue', `batch_size', `batch_timeout',
%% `export_timeout'.
-spec new(map()) -> batcher().
new(#{admission := Key, callbacks := Callbacks} = Opts) ->
  ok = instrument_admission:init(Key, maps:get(max_queue, Opts, 2048)),
  #batcher{
    admission = Key,
    callbacks = Callbacks,
    batch_size = maps:get(batch_size, Opts, 512),
    batch_timeout = maps:get(batch_timeout, Opts, 5000),
    export_timeout = maps:get(export_timeout, Opts, 30000)
  }.

%% @doc Adds `N' admitted items (oldest first) to the batch.
-spec add([term()], non_neg_integer(), batcher()) -> batcher().
add([], _N, B) ->
  B;
add(Items, N, #batcher{batch = Batch, count = Count} = B) ->
  B1 = start_timer(B#batcher{batch = lists:reverse(Items, Batch), count = Count + N}),
  case B1#batcher.count >= B1#batcher.batch_size of
    true -> maybe_export(B1);
    false -> B1
  end.

-spec add_exporter(exporter(), batcher()) -> batcher().
add_exporter(Exporter, #batcher{exporters = Exporters} = B) ->
  B#batcher{exporters = [Exporter | Exporters]}.

%% @doc Removes exporters for `Module'; returns the removed ones.
-spec remove_exporter(module(), batcher()) -> {[exporter()], batcher()}.
remove_exporter(Module, #batcher{exporters = Exporters} = B) ->
  {Removed, Remaining} = lists:partition(fun(#{module := M}) -> M =:= Module end,
                                         Exporters),
  {Removed, B#batcher{exporters = Remaining}}.

-spec exporters(batcher()) -> [exporter()].
exporters(#batcher{exporters = Exporters}) ->
  Exporters.

%% @doc Replies to `From' once everything batched so far is exported and the
%% exporters are flushed.
-spec flush(gen_server:from(), batcher()) -> batcher().
flush(From, #batcher{inflight = undefined, count = 0} = B) ->
  B1 = force_flush(B),
  gen_server:reply(From, ok),
  B1;
flush(From, #batcher{inflight = undefined, waiting = Waiting} = B) ->
  start_export(B#batcher{waiting = [From | Waiting]});
flush(From, #batcher{waiting = Waiting} = B) ->
  B#batcher{waiting = [From | Waiting]}.

%% @doc Handles the batcher's own messages. Returns `ignore' for others.
-spec handle_info(term(), batcher()) -> {ok, batcher()} | ignore.
handle_info({batcher_timeout, TRef}, #batcher{timer_ref = TRef} = B) ->
  {ok, maybe_export(B#batcher{timer_ref = undefined})};
handle_info({batcher_timeout, _Stale}, B) ->
  {ok, B};
handle_info({batcher_done, Ref, States}, #batcher{inflight = #{ref := Ref}} = B) ->
  {ok, finish(States, B)};
handle_info({batcher_kill, Ref}, #batcher{inflight = #{ref := Ref, pid := Pid}} = B) ->
  exit(Pid, kill),
  {ok, finish([], B)};
handle_info({'DOWN', Mon, process, _, _}, #batcher{inflight = #{monitor := Mon}} = B) ->
  {ok, finish([], B)};
handle_info({batcher_done, _Ref, _}, B) ->
  {ok, B};
handle_info({batcher_kill, _Ref}, B) ->
  {ok, B};
handle_info(_Msg, _B) ->
  ignore.

%% @doc Synchronously waits for the in-flight export, then exports what is
%% left. Used on shutdown, where the server cannot return to its loop.
-spec drain(batcher()) -> batcher().
drain(#batcher{inflight = undefined, count = 0} = B) ->
  reply_waiting(cancel_timer(B));
drain(#batcher{inflight = undefined} = B) ->
  drain(start_export(B));
drain(#batcher{inflight = #{ref := Ref, monitor := Mon, pid := Pid, froms := Froms},
               export_timeout = Timeout} = B) ->
  States = receive
             {batcher_done, Ref, S} -> S;
             {'DOWN', Mon, process, _, _} -> []
           after Timeout ->
             exit(Pid, kill),
             []
           end,
  B1 = apply_states(States, settle(B)),
  %% Callers waiting on that export are answered once everything is drained.
  drain(B1#batcher{waiting = Froms ++ B1#batcher.waiting}).

%% @doc Shuts down every exporter and forgets them.
-spec shutdown_exporters(batcher()) -> batcher().
shutdown_exporters(#batcher{exporters = Exporters,
                            callbacks = #{shutdown := Shutdown}} = B) ->
  lists:foreach(fun(#{module := M, state := S}) ->
    instrument_lib:safe_call(fun() -> Shutdown(M, S) end, ok)
  end, Exporters),
  B#batcher{exporters = []}.

%% ============================================================================
%% Internal
%% ============================================================================

maybe_export(#batcher{inflight = undefined, count = Count} = B) when Count > 0 ->
  start_export(B);
maybe_export(B) ->
  B.

%% Hand the batch to a worker. The items leave the server's queue here, so
%% their admission slots are released.
start_export(#batcher{batch = Batch, count = Count, exporters = Exporters,
                      callbacks = #{export := Export},
                      export_timeout = Timeout, admission = Key,
                      waiting = Waiting} = B) ->
  ok = instrument_admission:release(Key, Count),
  Items = lists:reverse(Batch),
  B0 = cancel_timer(B#batcher{batch = [], count = 0, waiting = []}),
  {Async, Sync} = lists:partition(fun(#{module := M}) -> is_async(M) end, Exporters),
  %% In-process exporters first, in this process.
  SyncStates = [{M, export_one(Export, M, Items, S)}
                || #{module := M, state := S} <- Sync, Items =/= []],
  B1 = apply_states(SyncStates, B0),
  case [E || E <- Async, Items =/= []] of
    [] ->
      finish([], B1#batcher{inflight = #{froms => Waiting}});
    AsyncExporters ->
      Parent = self(),
      Ref = make_ref(),
      {Pid, Mon} = erlang:spawn_monitor(fun() ->
        States = [{M, export_one(Export, M, Items, S)}
                  || #{module := M, state := S} <- AsyncExporters],
        Parent ! {batcher_done, Ref, States}
      end),
      Kill = erlang:send_after(Timeout, Parent, {batcher_kill, Ref}),
      Inflight = #{ref => Ref, pid => Pid, monitor => Mon, kill => Kill,
                   froms => Waiting},
      B1#batcher{inflight = Inflight}
  end.

is_async(M) ->
  _ = code:ensure_loaded(M),
  erlang:function_exported(M, export_async, 0)
    andalso instrument_lib:safe_call(fun() -> M:export_async() end, false) =:= true.

export_one(Export, M, Items, S) ->
  case instrument_config:is_exporter_enabled(M) of
    false -> S;
    true -> try Export(M, Items, S) catch _:_ -> S end
  end.

%% The worker finished (or was killed): adopt the new exporter states, reply
%% to flush callers, and start the next export if one is due.
finish(States, B) ->
  #batcher{inflight = #{froms := Froms}} = B,
  B1 = apply_states(States, settle(B)),
  B2 = case Froms of
         [] -> B1;
         _ ->
           B3 = force_flush(B1),
           [gen_server:reply(F, ok) || F <- Froms],
           B3
       end,
  case B2#batcher.waiting of
    [] when B2#batcher.count >= B2#batcher.batch_size -> start_export(B2);
    [] -> B2;
    _ when B2#batcher.count > 0 -> start_export(B2);
    _ -> reply_waiting(B2)
  end.

settle(#batcher{inflight = #{kill := Kill, monitor := Mon, ref := Ref}} = B) ->
  _ = erlang:cancel_timer(Kill),
  erlang:demonitor(Mon, [flush]),
  receive {batcher_kill, Ref} -> ok after 0 -> ok end,
  receive {batcher_done, Ref, _} -> ok after 0 -> ok end,
  B#batcher{inflight = undefined};
settle(B) ->
  %% No worker was started (only in-process exporters).
  B#batcher{inflight = undefined}.

%% Exporters registered or removed while the export ran keep their current
%% state; only exporters still present take the worker's result.
apply_states(States, #batcher{exporters = Exporters} = B) ->
  Updated = [case lists:keyfind(M, 1, States) of
               {M, NewS} -> E#{state := NewS};
               false -> E
             end || #{module := M} = E <- Exporters],
  B#batcher{exporters = Updated}.

reply_waiting(#batcher{waiting = []} = B) ->
  B;
reply_waiting(#batcher{waiting = Waiting} = B) ->
  B1 = force_flush(B),
  [gen_server:reply(F, ok) || F <- Waiting],
  B1#batcher{waiting = []}.

force_flush(#batcher{exporters = Exporters, callbacks = #{force_flush := Flush}} = B) ->
  Flushed = [E#{state := instrument_lib:safe_call(fun() -> Flush(M, S) end, S)}
             || #{module := M, state := S} = E <- Exporters],
  B#batcher{exporters = Flushed}.

start_timer(#batcher{timer_ref = undefined, batch_timeout = Timeout} = B) ->
  TRef = make_ref(),
  _ = erlang:send_after(Timeout, self(), {batcher_timeout, TRef}),
  B#batcher{timer_ref = TRef};
start_timer(B) ->
  B.

%% The timeout message carries a ref; a stale one is ignored, so there is no
%% timer to cancel.
cancel_timer(B) ->
  B#batcher{timer_ref = undefined}.
