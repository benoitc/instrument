%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_registry).
-author("benoitc").

%% API
-export([
  start_link/0,
  register/1,
  unregister/1,
  unregister_all/0,
  with/2
]).

-export([
  remove_label/2,
  clear_labels/1
]).

%% persistent_term based lookup API
-export([
  lookup/1,
  collect_all/0
]).

%% Cardinality / overflow API
-export([
  label_count/1,
  cardinality_dropped/1,
  overflow_sentinel/1
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, code_change/3, terminate/2]).

-include("instrument.hrl").

-define(LABEL_COUNTS_TABLE, instrument_label_counts).
-define(OVERFLOW_VALUE, <<"otel.metric.overflow">>).

%% State record - metrics_set is the source of truth for registered metric names
-record(state, {
  metrics_set = sets:new() :: sets:set(term())
}).

%% API

start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Route by shape:
%%   - collect = {M,F,A}       → series-store custom collector
%%   - anything else (e.g. handle=undefined, collect=undefined) → legacy
%%     gen_server (raw #metric records registered directly, e.g. by tests)
register(#metric{name = N, collect = {M, F, A}}) ->
  instrument_series:ensure_custom(N, {M, F, A}),
  ok;
register(Metric) ->
  gen_server:call(?MODULE, {reg, Metric}).

unregister(Name) ->
  gen_server:call(?MODULE, {unreg, Name}).

unregister_all() ->
  gen_server:call(?MODULE, unregister_all).


%% A record-held simple metric writes through its own handle directly. A
%% by-name reference resolves the unlabeled {[], []} row from the series store,
%% falling back to a raw #metric registered directly in ETS (registry_SUITE
%% registers such records with handle = undefined).
with(#metric{} = M, Fun) ->
  Fun(M);
with(Name, Fun) ->
  case persistent_term:get({instrument_label, Name, {[], []}}, undefined) of
    #metric{} = Row -> Fun(Row#metric{name = Name});
    undefined ->
      %% legacy fallback: raw #metric records (no series-store row)
      case ets:lookup(instrument_lib:table(), Name) of
        [#metric{} = M] -> Fun(M);
        [] -> {error, not_found}
      end
  end.


%% INTERNAL VECTOR API (legacy labeled-metric teardown over the series store)

remove_label(Name, Label) ->
  gen_server:call(?MODULE, {remove_label, Name, Label}).

clear_labels(Name) ->
  gen_server:call(?MODULE, {clear_labels, Name}).


%% gen_server callbacks

init([]) ->
  _ = create_tables(),
  _ = create_label_counts_table(),
  %% A registry restart is a clean slate: erase any stale instrument-owned
  %% persistent_term entries left by a previous incarnation before resetting
  %% the index, so get_instrument/1 returns undefined and create_* re-registers.
  clear_instrument_persistent_terms(),
  %% Initialize persistent_term index as empty
  persistent_term:put(instrument_metrics, []),
  ok = instrument_series:init(),
  {ok, #state{metrics_set = sets:new()}}.


create_tables() ->
  [ets:new(T, [public, named_table, set, {keypos,#metric.name}]) || T <- tables()].

create_label_counts_table() ->
  case ets:info(?LABEL_COUNTS_TABLE, name) of
    undefined ->
      ets:new(?LABEL_COUNTS_TABLE,
              [public, named_table, set, {write_concurrency, true}]);
    _ ->
      ok
  end.

handle_call({reg, #metric{name=N}=Metric}, _From, #state{metrics_set = Set} = State) ->
  case ets:member(instrument_lib:table(), N) of
    true ->
      {reply, {error, already_exists}, State};
    false ->
      do_reg_metric(Metric),
      NewSet = sets:add_element(N, Set),
      sync_metrics_index(NewSet),
      {reply, ok, State#state{metrics_set = NewSet}}
  end;

handle_call({unreg, Name}, _From, #state{metrics_set = Set} = State) ->
  do_unreg_metric(Name),
  NewSet = sets:del_element(Name, Set),
  sync_metrics_index(NewSet),
  {reply, ok, State#state{metrics_set = NewSet}};

handle_call(unregister_all, _From, _State) ->
  do_delete_all(),
  _ = erlang:garbage_collect(self()),
  {reply, ok, #state{metrics_set = sets:new()}};


handle_call({remove_label, Name, Label}, _From, State) ->
  ok = instrument_series:remove_row(Name, Label),
  {reply, ok, State};

handle_call({clear_labels, Name}, _From, State) ->
  ok = instrument_series:clear_family_rows(Name),
  {reply, ok, State};

handle_call(Req, _From, State) ->
  {stop, {unhandled_call, Req}, State}.

handle_cast(Msg, State) ->
  {stop, {unhandled_cast, Msg}, State}.

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% @private Register a metric in ETS and persistent_term (for fast lookup).
%% Does NOT update the metrics index - that's handled by the gen_server state.
do_reg_metric(Metric) ->
  #metric{name = Name} = Metric,
  %% Store in ETS tables
  [ets:insert(T, Metric) || T <- tables()],
  %% Store in persistent_term for fast lookup
  persistent_term:put({instrument_metric, Name}, Metric).

%% @private Unregister a metric from ETS and persistent_term.
%% Does NOT update the metrics index - that's handled by the gen_server state.
do_unreg_metric(Name) ->
  %% Tear down the series-store family for `Name' (chain rows, cache keys,
  %% arbiter rows, exemplar reservoirs, family meta, and cardinality
  %% accounting). This is the full teardown for both vec families and meter
  %% instruments backed by the store.
  ok = instrument_series:teardown_family(Name),
  %% Legacy path: a raw #metric registered directly in ETS (no series-store
  %% family) — release its reservoirs and delete its rows.
  Metric = case ets:lookup(instrument_lib:table(), Name) of
             [M] -> M;
             [] -> undefined
           end,
  [ets:delete(T, Name) || T <- tables()],
  try persistent_term:erase({instrument_metric, Name}) catch _:_ -> ok end,
  _ = release_exemplar_reservoirs(Metric),
  ok.

%% @private Release all exemplar reservoirs from all series-store families.
%% Must be called before clear_instrument_persistent_terms/0 wipes the row keys.
release_series_store_all_reservoirs() ->
  case persistent_term:get(instrument_family_seq, undefined) of
    undefined -> ok;
    FamSeq ->
      N = atomics:get(FamSeq, 1),
      lists:foreach(fun(K) ->
        case persistent_term:get({instrument_family_idx, K}, undefined) of
          undefined -> ok;
          Name ->
            case persistent_term:get({instrument_family, Name}, undefined) of
              #family{row_seq = Seq} ->
                RowN = atomics:get(Seq, 1),
                lists:foreach(fun(S) ->
                  case persistent_term:get({instrument_row, Name, S}, undefined) of
                    undefined -> ok;
                    {_Canon, _CacheKey, Row} ->
                      instrument_histogram:cleanup(Row)
                  end
                end, lists:seq(1, RowN));
              _ -> ok
            end
        end
      end, lists:seq(1, N))
  end.

%% @private Sync the metrics index from gen_server state to persistent_term.
%% This is the only place the instrument_metrics list is written.
sync_metrics_index(Set) ->
  persistent_term:put(instrument_metrics, sets:to_list(Set)).

%% @private Release the exemplar reservoir owned by a raw #metric (legacy
%% directly-registered records). Series-store rows are cleaned by
%% instrument_series:teardown_family/1.
release_exemplar_reservoirs(undefined) ->
  ok;
release_exemplar_reservoirs(#metric{} = Metric) ->
  instrument_histogram:cleanup(Metric).

do_delete_all() ->
  %% Release histogram exemplar reservoirs from series-store families before
  %% clearing persistent_term (the pt keys are needed to walk the row chains).
  release_series_store_all_reservoirs(),
  %% Release histogram exemplar reservoirs for every registered metric
  %% before we wipe the tables.
  AllMetrics = case instrument_lib:tables() of
                 [T | _] -> ets:tab2list(T);
                 [] -> []
               end,
  lists:foreach(fun release_exemplar_reservoirs/1, AllMetrics),
  [ets:delete_all_objects(T) || T <- instrument_lib:tables()],
  %% Clear all instrument-owned persistent_term entries (this also sweeps
  %% instrument_family_seq, so the series store must be re-initialized below).
  clear_instrument_persistent_terms(),
  %% Re-establish a clean series store: re-mint the family-seq ref the sweep
  %% just erased and drop the arbiter rows of the families we deleted.
  ok = instrument_series:reset(),
  %% Clear label accounting
  case ets:info(?LABEL_COUNTS_TABLE, name) of
    undefined -> ok;
    _ -> ets:delete_all_objects(?LABEL_COUNTS_TABLE)
  end,
  persistent_term:put(instrument_metrics, []).


%% Erase every instrument-owned persistent_term entry so a registry restart or
%% full reset is a clean slate. The NIF/atomics resources held by the erased
%% records are released by refcount when the entries are erased.
clear_instrument_persistent_terms() ->
  [persistent_term:erase(K)
   || {K, _} <- persistent_term:get(), is_instrument_key(K)].

%% instrument_row entries are published by the write path (claim_row/5) and must
%% be swept here so a registry restart produces a clean slate.
is_instrument_key(otel_instruments) ->
  true;
is_instrument_key(instrument_family_seq) ->
  true;
is_instrument_key(K) when is_tuple(K), tuple_size(K) >= 2 ->
  case element(1, K) of
    instrument_metric         -> true;
    instrument_label          -> true;
    instrument_label_overflow -> true;
    otel_instrument           -> true;
    instrument_family         -> true;
    instrument_family_idx     -> true;
    instrument_row            -> true;
    _                         -> false
  end;
is_instrument_key(_) ->
  false.


tables() -> instrument_lib:tables().

%% persistent_term based lookup API

%% Returns #family{} for series-store families; falls back to the legacy
%% {instrument_metric, Name} pt entry for raw #metric records registered
%% directly via register/1 (e.g. registry_SUITE's bare records).
-spec lookup(term()) -> #family{} | {custom, term(), pos_integer()} | #metric{} | undefined.
lookup(Name) ->
  case instrument_series:family(Name) of
    undefined ->
      persistent_term:get({instrument_metric, Name}, undefined);
    Meta ->
      Meta
  end.

%% @doc Returns the number of distinct label sets currently cached for `Name'.
-spec label_count(term()) -> non_neg_integer().
label_count(Name) ->
  case ets:info(?LABEL_COUNTS_TABLE, name) of
    undefined -> 0;
    _ ->
      case ets:lookup(?LABEL_COUNTS_TABLE, {count, Name}) of
        [{_, N}] -> N;
        [] -> 0
      end
  end.

%% @doc Returns the number of label sets dropped into the overflow bucket
%% for `Name' since the registry started (or the metric was last registered).
-spec cardinality_dropped(term()) -> non_neg_integer().
cardinality_dropped(Name) ->
  case ets:info(?LABEL_COUNTS_TABLE, name) of
    undefined -> 0;
    _ ->
      case ets:lookup(?LABEL_COUNTS_TABLE, {dropped, Name}) of
        [{_, N}] -> N;
        [] -> 0
      end
  end.

%% @doc Returns the overflow row #metric{} for `Name' if the cardinality cap
%% has been hit (and the overflow series therefore created), `undefined'
%% otherwise. The overflow series is an ordinary series-store row whose canon
%% is the per-API overflow shape: for a vec family that is the declared label
%% names (sorted) with every value <<"otel.metric.overflow">>; for a
%% schema-free family it is {[<<"otel.metric.overflow">>], [<<"true">>]}. The
%% row carries the accumulated dropped writes, so callers can read its value.
-spec overflow_sentinel(term()) -> #metric{} | undefined.
overflow_sentinel(Name) ->
  case instrument_series:family(Name) of
    #family{declared_labels = Declared} ->
      OverflowCanon = overflow_canon(Declared),
      persistent_term:get({instrument_label, Name, OverflowCanon}, undefined);
    _ ->
      undefined
  end.

overflow_canon(undefined) ->
  {[?OVERFLOW_VALUE], [<<"true">>]};
overflow_canon(Declared) ->
  Sorted = lists:sort(Declared),
  {Sorted, [?OVERFLOW_VALUE || _ <- Sorted]}.

-spec collect_all() -> [map()].
collect_all() ->
  %% transitional: series-store families first, then the legacy index (the
  %% legacy half is deleted when the last producer is cut over)
  instrument_series:collect_all() ++ legacy_collect_all().

legacy_collect_all() ->
  Names = persistent_term:get(instrument_metrics, []),
  lists:filtermap(fun(Name) ->
    case lookup(Name) of
      undefined -> false;
      #metric{collect = {Mod, Fun, Args}} ->
        try
          {true, erlang:apply(Mod, Fun, Args)}
        catch
          Class:Reason:Stacktrace ->
            logger:warning("Metric collector ~p:~p failed: ~p:~p",
                          [Mod, Fun, Class, Reason],
                          #{error_logger => #{tag => warning_msg},
                            mfa => {Mod, Fun, length(Args)},
                            stacktrace => Stacktrace}),
            false
        end
    end
  end, Names).