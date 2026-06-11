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
  clear_labels/1,
  create_vector_metric/2
]).

%% persistent_term based lookup API
-export([
  lookup/1,
  lookup_label/2,
  cache_label/3,
  collect_all/0
]).

%% Cardinality / overflow API
-export([
  label_count/1,
  cardinality_dropped/1,
  overflow_sentinel/1,
  get_or_create_overflow/1
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
%%   - #vector{} handle        → legacy gen_server (vec API, Task 7)
%%   - collect = {M,F,A}       → series-store custom collector
%%   - anything else (e.g. handle=undefined, collect=undefined) → legacy gen_server
register(#metric{handle = #vector{}} = Metric) ->
  gen_server:call(?MODULE, {reg, Metric});
register(#metric{name = N, collect = {M, F, A}}) ->
  instrument_series:ensure_custom(N, {M, F, A}),
  ok;
register(Metric) ->
  gen_server:call(?MODULE, {reg, Metric}).

unregister(Name) ->
  gen_server:call(?MODULE, {unreg, Name}).

unregister_all() ->
  gen_server:call(?MODULE, unregister_all).


%% Vec metrics are looked up by name so the caller always sees the freshest
%% labels_map from ETS — the caller-held record may be stale. Task 7 removes
%% this clause when the vec API is cut over to the series store.
with(#metric{name = Name, handle = #vector{}}, Fun) ->
  with(Name, Fun);
with(#metric{} = M, Fun) ->
  Fun(M);
with(Name, Fun) ->
  case persistent_term:get({instrument_label, Name, {[], []}}, undefined) of
    #metric{} = Row -> Fun(Row#metric{name = Name});
    undefined ->
      %% legacy fallback: vec families until Task 7
      case ets:lookup(instrument_lib:table(), Name) of
        [#metric{} = M] -> Fun(M);
        [] -> {error, not_found}
      end
  end.


%% INTERNAL VECTOR API

remove_label(Name, Label) ->
  gen_server:call(?MODULE, {remove_label, Name, Label}).

clear_labels(Name) ->
  gen_server:call(?MODULE, {clear_labels, Name}).

create_vector_metric(Name, Label) ->
  gen_server:call(?MODULE, {create_vector_metric, Name, Label}).


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


handle_call({create_vector_metric, Name, Label}, _From, State) ->
  Reply = case ets:lookup(instrument_lib:table(), Name) of
            [] -> ok;
            [Metric] ->
              Metric2 = do_create_metric(Metric, Label),
              do_reg_metric(Metric2),
              ok
          end,
  {reply, Reply, State};

handle_call({create_overflow, Name}, _From, State) ->
  Reply = case persistent_term:get({instrument_label_overflow, Name}, undefined) of
            undefined -> do_create_overflow(Name);
            _ -> ok
          end,
  {reply, Reply, State};

handle_call({remove_label, Name, Label}, _From, State) ->
  Reply = case ets:lookup(instrument_lib:table(), Name) of
            [] -> ok;
            [Metric] ->
              Metric2 = do_remove_label(Metric, Label),
              do_reg_metric(Metric2),
              ok
          end,
  {reply, Reply, State};

handle_call({clear_labels, Name}, _From, State) ->
  Reply = case ets:lookup(instrument_lib:table(), Name) of
            [] -> ok;
            [Metric] ->
              Metric2 = do_clear_labels(Metric),
              do_reg_metric(Metric2),
              ok
          end,
  {reply, Reply, State};

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
  %% Release series-store rows (exemplar reservoirs) for names backed by
  %% the series store. Full teardown of pt keys is Task 8; the minimum
  %% needed here is freeing exemplar resources to avoid leaks.
  release_series_store_rows(Name),
  %% Read the metric first so we can drive cleanup from its #vector.labels_map
  %% and release any histogram exemplar reservoirs it owns.
  Metric = case ets:lookup(instrument_lib:table(), Name) of
             [M] -> M;
             [] -> undefined
           end,
  %% Delete from all ETS tables (they're partitioned by scheduler)
  [ets:delete(T, Name) || T <- tables()],
  %% Remove from persistent_term
  try persistent_term:erase({instrument_metric, Name}) catch _:_ -> ok end,
  try persistent_term:erase({instrument_label_overflow, Name}) catch _:_ -> ok end,
  %% Erase cached labels for this metric
  _ = erase_cached_labels(Name, Metric),
  _ = release_exemplar_reservoirs(Metric),
  _ = reset_label_accounting(Name),
  ok.

%% @private Release exemplar reservoirs owned by series-store rows for `Name'.
%% Walks the row chain and calls histogram cleanup on each row.
release_series_store_rows(Name) ->
  case instrument_series:family(Name) of
    #family{row_seq = Seq} ->
      N = atomics:get(Seq, 1),
      lists:foreach(fun(S) ->
        case persistent_term:get({instrument_row, Name, S}, undefined) of
          undefined -> ok;
          {_Canon, _CacheKey, Row} ->
            instrument_histogram:cleanup(Row)
        end
      end, lists:seq(1, N));
    _ ->
      ok
  end.

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

%% @private Drop any cached {instrument_label, Name, LabelValues} entries for
%% this metric. Iterates the metric's own labels_map rather than scanning the
%% global persistent_term index, which would be O(total persistent_term size).
erase_cached_labels(_Name, undefined) ->
  0;
erase_cached_labels(Name, #metric{handle = #vector{labels_map = LabelsMap}}) ->
  maps:fold(fun(LabelValues, _, Acc) ->
    case persistent_term:get({instrument_label, Name, LabelValues}, undefined) of
      undefined -> Acc;
      _ ->
        persistent_term:erase({instrument_label, Name, LabelValues}),
        Acc + 1
    end
  end, 0, LabelsMap);
erase_cached_labels(_Name, _Metric) ->
  0.

%% @private Release exemplar reservoirs owned by a metric. For vector
%% metrics this walks every label-specific handle; for simple metrics it
%% delegates directly to the histogram cleanup helper.
release_exemplar_reservoirs(undefined) ->
  ok;
release_exemplar_reservoirs(#metric{handle = #vector{labels_map = LabelsMap}}) ->
  maps:foreach(fun(_, LabelMetric) ->
    instrument_histogram:cleanup(LabelMetric)
  end, LabelsMap);
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
%% {instrument_metric, Name} pt entry for vec families until Task 7.
-spec lookup(term()) -> #family{} | #metric{} | undefined.
lookup(Name) ->
  case instrument_series:family(Name) of
    undefined ->
      %% legacy fallback: vec entries until Task 7
      persistent_term:get({instrument_metric, Name}, undefined);
    Meta ->
      Meta
  end.

-spec lookup_label(term(), list()) -> #metric{} | undefined.
lookup_label(Name, LabelValues) ->
  persistent_term:get({instrument_label, Name, LabelValues}, undefined).

-spec cache_label(term(), list(), #metric{}) -> ok.
cache_label(Name, LabelValues, Metric) ->
  case persistent_term:get({instrument_label, Name, LabelValues}, undefined) of
    undefined ->
      persistent_term:put({instrument_label, Name, LabelValues}, Metric),
      _ = incr_label_count(Name),
      ok;
    _ ->
      persistent_term:put({instrument_label, Name, LabelValues}, Metric),
      ok
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

%% @doc Returns the cached overflow sentinel metric for `Name' if one has
%% been created, `undefined' otherwise.
-spec overflow_sentinel(term()) -> #metric{} | undefined.
overflow_sentinel(Name) ->
  persistent_term:get({instrument_label_overflow, Name}, undefined).

%% @doc Returns the overflow sentinel metric for `Name', creating it on the
%% first call. Also increments the dropped-cardinality counter for `Name'.
%% Returns `undefined' if the parent metric does not exist.
-spec get_or_create_overflow(term()) -> #metric{} | undefined.
get_or_create_overflow(Name) ->
  _ = incr_dropped_count(Name),
  case persistent_term:get({instrument_label_overflow, Name}, undefined) of
    undefined ->
      _ = gen_server:call(?MODULE, {create_overflow, Name}),
      persistent_term:get({instrument_label_overflow, Name}, undefined);
    Metric ->
      Metric
  end.

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

%% Internal vector functions

do_create_metric(Metric, Label) ->
  #metric{ handle = Vector } = Metric,
  #vector{ labels_map = LabelsMap } = Vector,
  case maps:find(Label, LabelsMap) of
    {ok, _} -> Metric;
    error ->
      M = mk_metric(Vector),
      Vector2 = Vector#vector{labels_map=maps:put(Label, M, LabelsMap)},
      Metric#metric{handle=Vector2}
  end.

mk_metric(#vector{ name=Name, help=Help, metric=counter }) ->
  instrument_counter:new_counter(Name, Help);
mk_metric(#vector{ name=Name, help=Help, metric=gauge }) ->
  instrument_gauge:new_gauge(Name, Help);
mk_metric(#vector{ name=Name, help=Help, metric=observable_counter }) ->
  instrument_gauge:new_gauge(Name, Help);
mk_metric(#vector{ name=Name, help=Help, metric=histogram, buckets=Buckets }) ->
  instrument_histogram:new_histogram(Name, Help, Buckets).

do_remove_label(#metric{ name = Name, handle = Vector } = Metric, Label) ->
  #vector{ labels_map = LabelsMap } = Vector,
  %% Erase the cache entry for this specific label
  case persistent_term:get({instrument_label, Name, Label}, undefined) of
    undefined -> ok;
    _ ->
      persistent_term:erase({instrument_label, Name, Label}),
      _ = decr_label_count(Name, 1)
  end,
  Vector2 = Vector#vector{labels_map=maps:remove(Label, LabelsMap)},
  Metric#metric{handle=Vector2}.

do_clear_labels(#metric{ name = Name, handle = Vector } = Metric) ->
  #vector{ labels_map = LabelsMap } = Vector,
  %% Erase cache entries for all labels
  Erased = maps:fold(fun(LabelValues, _, Acc) ->
    case persistent_term:get({instrument_label, Name, LabelValues}, undefined) of
      undefined -> Acc;
      _ ->
        persistent_term:erase({instrument_label, Name, LabelValues}),
        Acc + 1
    end
  end, 0, LabelsMap),
  case Erased of
    0 -> ok;
    _ -> decr_label_count(Name, Erased)
  end,
  Vector2 = Vector#vector{labels_map=#{}},
  Metric#metric{handle=Vector2}.

%% @private Create the overflow sentinel metric for `Name'. Must be called
%% from the gen_server so that only one overflow metric is created per name.
do_create_overflow(Name) ->
  case ets:lookup(instrument_lib:table(), Name) of
    [] -> {error, not_found};
    [#metric{handle = #vector{labels = LabelNames}} = Parent] ->
      OverflowLabels = [?OVERFLOW_VALUE || _ <- LabelNames],
      Parent2 = do_create_metric(Parent, OverflowLabels),
      do_reg_metric(Parent2),
      case (Parent2#metric.handle)#vector.labels_map of
        #{OverflowLabels := Sentinel} ->
          persistent_term:put({instrument_label_overflow, Name}, Sentinel),
          ok;
        _ ->
          {error, not_found}
      end;
    _ ->
      {error, not_a_vector}
  end.

%% @private Reset all label-accounting state for `Name'.
reset_label_accounting(Name) ->
  case ets:info(?LABEL_COUNTS_TABLE, name) of
    undefined -> ok;
    _ ->
      ets:delete(?LABEL_COUNTS_TABLE, {count, Name}),
      ets:delete(?LABEL_COUNTS_TABLE, {dropped, Name}),
      ok
  end.

incr_label_count(Name) ->
  ets:update_counter(?LABEL_COUNTS_TABLE, {count, Name}, {2, 1}, {{count, Name}, 0}).

decr_label_count(_Name, 0) ->
  ok;
decr_label_count(Name, N) when N > 0 ->
  ets:update_counter(?LABEL_COUNTS_TABLE, {count, Name},
                     {2, -N, 0, 0}, {{count, Name}, 0}),
  ok.

incr_dropped_count(Name) ->
  ets:update_counter(?LABEL_COUNTS_TABLE, {dropped, Name}, {2, 1}, {{dropped, Name}, 0}).