%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @private Bounded intake for export processes.
%%
%% A process that receives items by cast (spans, log records) cannot bound
%% its own mailbox: by the time it sees a message, the message is already
%% queued. An admission counter moves the check to the sender. The sender
%% calls admit/2 before casting and drops the item when the receiver already
%% holds `Max' items (in its mailbox or its batch); the receiver calls
%% release/2 once items leave its queue.
%%
%% The counter is an `atomics' array published under a `persistent_term' key
%% that is written once per receiver start, so admission costs one
%% `persistent_term:get/2' and one atomic add on the sender's side.
-module(instrument_admission).

-export([
  init/2,
  admit/2,
  release/2,
  queued/1,
  dropped/1,
  record_drop/2
]).

-define(QUEUED, 1).
-define(DROPPED, 2).

%% @doc Creates (or resets) the counter under `Key' with limit `Max'.
%% The dropped count is kept across restarts of the receiver.
-spec init(term(), pos_integer()) -> ok.
init(Key, Max) when is_integer(Max), Max > 0 ->
  case persistent_term:get(Key, undefined) of
    {Ref, Max} ->
      atomics:put(Ref, ?QUEUED, 0);
    {Ref, _OtherMax} ->
      atomics:put(Ref, ?QUEUED, 0),
      persistent_term:put(Key, {Ref, Max});
    undefined ->
      persistent_term:put(Key, {atomics:new(2, [{signed, true}]), Max})
  end,
  ok.

%% @doc Reserves room for `N' items. Returns `false', and counts them as
%% dropped, when that would exceed the limit. Admits everything when the
%% counter does not exist (receiver not started yet).
-spec admit(term(), pos_integer()) -> boolean().
admit(Key, N) ->
  case persistent_term:get(Key, undefined) of
    undefined ->
      true;
    {Ref, Max} ->
      case atomics:add_get(Ref, ?QUEUED, N) of
        Queued when Queued =< Max ->
          true;
        _ ->
          atomics:sub(Ref, ?QUEUED, N),
          atomics:add(Ref, ?DROPPED, N),
          false
      end
  end.

%% @doc Releases `N' items that left the receiver's queue.
-spec release(term(), non_neg_integer()) -> ok.
release(_Key, 0) ->
  ok;
release(Key, N) ->
  case persistent_term:get(Key, undefined) of
    undefined -> ok;
    {Ref, _Max} ->
      case atomics:sub_get(Ref, ?QUEUED, N) of
        Q when Q < 0 -> atomics:put(Ref, ?QUEUED, 0);
        _ -> ok
      end
  end.

%% @doc Counts `N' items dropped by the receiver itself (for example after a
%% failed export), so dropped/1 reports every loss in one place.
-spec record_drop(term(), non_neg_integer()) -> ok.
record_drop(_Key, 0) ->
  ok;
record_drop(Key, N) ->
  case persistent_term:get(Key, undefined) of
    undefined -> ok;
    {Ref, _Max} -> atomics:add(Ref, ?DROPPED, N)
  end.

%% @doc Items currently admitted and not yet released.
-spec queued(term()) -> non_neg_integer().
queued(Key) ->
  case persistent_term:get(Key, undefined) of
    undefined -> 0;
    {Ref, _Max} -> max(0, atomics:get(Ref, ?QUEUED))
  end.

%% @doc Items dropped since the counter was created.
-spec dropped(term()) -> non_neg_integer().
dropped(Key) ->
  case persistent_term:get(Key, undefined) of
    undefined -> 0;
    {Ref, _Max} -> atomics:get(Ref, ?DROPPED)
  end.
