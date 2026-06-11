%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc The registry is the metrics subsystem's janitor and table owner. It no
%% longer holds any per-metric state: the series store (instrument_series) owns
%% every family and row in persistent_term, and the registry only
%%   - owns the label-counts ETS table,
%%   - sweeps stale instrument-owned persistent_term on restart (clean slate),
%%   - serializes admin-time teardown (unregister / unregister_all / label ops)
%%     through its single mailbox so concurrent removals can't interleave.
%% register/1 is a thin shim onto instrument_series:ensure_custom/2 for the
%% record-based API; everything else (counters, gauges, histograms, vecs, the
%% meter) registers families directly through instrument_series.
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

%% exported for test use (sweep-coverage assertions); not a public API
-export([is_instrument_key/1]).

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

%% API

start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Register a record-based metric as a series-store custom family. Two shapes:
%%   - collect = {M,F,A}  → a custom collector scraped by collect_all/0
%%   - any other record   → stored verbatim as {raw, Metric}; lookup/1 round-trips
%%                          it and collect_all/0 skips it (no collector to call).
%% Returns {error, already_exists} if the name is taken.
-spec register(#metric{}) -> ok | {error, already_exists}.
register(#metric{name = N, collect = {M, F, A}}) ->
  instrument_series:ensure_custom(N, {M, F, A});
register(#metric{name = N} = Metric) ->
  instrument_series:ensure_custom(N, {raw, Metric}).

unregister(Name) ->
  gen_server:call(?MODULE, {unreg, Name}).

unregister_all() ->
  gen_server:call(?MODULE, unregister_all).


%% A record-held simple metric writes through its own handle directly. A
%% by-name reference resolves the unlabeled {[], []} row from the series store,
%% falling back to the raw record of a record-based family (register/1 with no
%% collector) so by-name use of such a metric still resolves.
with(#metric{} = M, Fun) ->
  Fun(M);
with(Name, Fun) ->
  case persistent_term:get({instrument_label, Name, {[], []}}, undefined) of
    #metric{} = Row -> Fun(Row#metric{name = Name});
    undefined ->
      case instrument_series:family(Name) of
        {custom, {raw, #metric{} = M}, _Idx} -> Fun(M);
        _ -> {error, not_found}
      end
  end.


%% INTERNAL VECTOR API (labeled-metric teardown over the series store)

remove_label(Name, Label) ->
  gen_server:call(?MODULE, {remove_label, Name, Label}).

clear_labels(Name) ->
  gen_server:call(?MODULE, {clear_labels, Name}).


%% gen_server callbacks

init([]) ->
  _ = create_label_counts_table(),
  %% A registry restart is a clean slate: erase any stale instrument-owned
  %% persistent_term entries left by a previous incarnation so get_instrument/1
  %% returns undefined and create_* re-registers. instrument_series:init/0
  %% re-mints the family-seq ref the sweep just erased.
  clear_instrument_persistent_terms(),
  ok = instrument_series:init(),
  {ok, #{}}.


create_label_counts_table() ->
  case ets:info(?LABEL_COUNTS_TABLE, name) of
    undefined ->
      ets:new(?LABEL_COUNTS_TABLE,
              [public, named_table, set, {write_concurrency, true}]);
    _ ->
      ok
  end.

handle_call({unreg, Name}, _From, State) ->
  ok = instrument_series:teardown_family(Name),
  {reply, ok, State};

handle_call(unregister_all, _From, State) ->
  do_delete_all(),
  _ = erlang:garbage_collect(self()),
  {reply, ok, State};

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

%% @private Tear down every family (releasing exemplar reservoirs row by row via
%% the chain), then wipe whatever instrument-owned persistent_term the sweep can
%% reach, reset the series store's ETS state and seq ref, and clear label
%% accounting. Walking family_seq first means teardown_family/1 releases each
%% histogram's reservoir before clear_instrument_persistent_terms/0 erases the
%% row keys it needs to find them.
do_delete_all() ->
  teardown_all_families(),
  %% Clear all instrument-owned persistent_term entries (this also sweeps
  %% instrument_family_seq, so the series store must be re-initialized below).
  clear_instrument_persistent_terms(),
  %% Re-establish a clean series store: re-mint the family-seq ref the sweep
  %% just erased and drop any arbiter rows the teardown chain missed.
  ok = instrument_series:reset(),
  %% Clear label accounting
  case ets:info(?LABEL_COUNTS_TABLE, name) of
    undefined -> ok;
    _ -> ets:delete_all_objects(?LABEL_COUNTS_TABLE)
  end.

%% Walk the family-sequence chain and tear down each live family through the
%% same path unregister/1 uses, so reservoir cleanup and chain erasure stay in
%% one place.
teardown_all_families() ->
  case persistent_term:get(instrument_family_seq, undefined) of
    undefined -> ok;
    FamSeq ->
      N = atomics:get(FamSeq, 1),
      lists:foreach(fun(K) ->
        case persistent_term:get({instrument_family_idx, K}, undefined) of
          undefined -> ok;
          Name -> ok = instrument_series:teardown_family(Name)
        end
      end, lists:seq(1, N))
  end.


%% Erase every instrument-owned persistent_term entry so a registry restart or
%% full reset is a clean slate. The NIF/atomics resources held by the erased
%% records are released by refcount when the entries are erased.
clear_instrument_persistent_terms() ->
  [persistent_term:erase(K)
   || {K, _} <- persistent_term:get(), is_instrument_key(K)].

%% instrument_row entries are published by the write path (claim_row/5) and must
%% be swept here so a registry restart produces a clean slate. The legacy tuple
%% shapes (instrument_metric/instrument_label_overflow/otel_instrument) and the
%% bare-atom otel_instruments list carry no live writers since the series-store
%% cutover but are kept so an in-place upgrade from an older incarnation still
%% self-cleans.
%% master-1.1.3 shapes: never written by this branch; swept so an in-place upgrade self-cleans.
is_instrument_key(otel_instruments) ->
  true;
is_instrument_key(instrument_metrics) ->
  true;
is_instrument_key(instrument_family_seq) ->
  true;
is_instrument_key(K) when is_tuple(K), tuple_size(K) >= 2 ->
  case element(1, K) of
    instrument_metric         -> true;
    instrument_label          -> true;
    instrument_label_overflow -> true;
    otel_instrument           -> true;
    otel_instrument_vecs      -> true;
    instrument_family         -> true;
    instrument_family_idx     -> true;
    instrument_row            -> true;
    _                         -> false
  end;
is_instrument_key(_) ->
  false.


%% persistent_term based lookup API

%% Returns the family meta for series-store families. A record-based family
%% (register/1) stores its #metric{} as {custom, {raw, Metric}, _}; unwrap it so
%% lookup round-trips the original record. Custom-collector families return
%% their {custom, {M,F,A}, _} meta unchanged.
-spec lookup(term()) -> #family{} | {custom, term(), pos_integer()} | #metric{} | undefined.
lookup(Name) ->
  case instrument_series:family(Name) of
    {custom, {raw, #metric{} = Metric}, _Idx} -> Metric;
    Meta -> Meta
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
  instrument_series:collect_all().
