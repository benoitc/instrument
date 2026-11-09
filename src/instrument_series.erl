%% Copyright (c) 2026, Grigory Starinkin <starinkin@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc The series store: one family per logical metric name, one slot per
%% live label set.
%%
%% == Layout ==
%%
%% Cells are created ahead of use, in chunks of growing size (16, 32, ...,
%% capped at 1024 slots). Chunk 0 lives in the family meta; each later chunk
%% is one persistent_term key `{instrument_chunk, Name, Inc, C}' holding
%% `{Epochs, Rows}': an atomics array with one epoch per slot (odd = live)
%% and a tuple of pre-created `#metric{}' cells. Cells are mutable (NIF or
%% atomics), so a chunk is published once and never replaced. A family
%% therefore uses `2 + chunks' persistent_term keys whatever its cardinality,
%% and no create or write path replaces a key (a replace makes every process
%% scan its heap).
%%
%% Which label set sits in which slot is kept in ETS (`instrument_series',
%% keys prefixed `{'$s', Inc, ...}'), the source of truth for first writes and
%% scrapes. Writers cache `{Epochs, Ix, Epoch, Row}' per label set in their
%% process dictionary; a write checks that the slot's epoch is unchanged, so a
%% removed or reused slot is never written through a stale entry.
%%
%% Removed slots go to a free list and are reused after a quarantine
%% (`series_reuse_quarantine_ms', default 5000), with their cell reset. Slots
%% whose cell escaped as a handle (`labels/2', `get_or_create_label/2') are
%% pinned and never reused.
-module(instrument_series).

-include("instrument.hrl").

-export([
  init/0,
  reset/0,
  ensure_family/5,
  ensure_custom/2,
  family/1,
  write/4,
  write_unlabeled/3,
  resolve_row/3,
  unlabeled_row/1,
  overflow_row/1,
  fold_rows/2,
  live_count/1,
  dropped/1,
  ensure_chunk/3,
  kill_term/1,
  purge_cache/0,
  collect_all/0,
  remove_row/2,
  clear_family_rows/1,
  teardown_family/1,
  to_label_value/1,
  vec_canon/2,
  overflow_canon/1
]).

%% Test helpers
-export([slot_of/2, high_water/1]).

-define(TAB, instrument_series).
-define(FREE, instrument_series_free).
-define(OVERFLOW_VALUE, <<"otel.metric.overflow">>).
-define(UNLABELED, {[], []}).
-define(PD, '$instrument_series').
-define(PD_COUNT, '$instrument_series_n').
-define(PD_LIMIT, '$instrument_series_limit').
-define(PD_SWEEP, 8192).

%% counters slots
-define(HW, 1).
-define(LIVE, 2).
-define(DROPPED, 3).
-define(ALIASES, 4).

-define(FIRST_CHUNK, 16).
-define(MAX_CHUNK, 1024).

%% Called from instrument_table_owner:init/1, which owns the tables.
init() ->
  _ = ets:new(?TAB, [set, public, named_table, {write_concurrency, auto},
                     {read_concurrency, true}]),
  _ = ets:new(?FREE, [ordered_set, public, named_table, {write_concurrency, true}]),
  persistent_term:put(instrument_family_seq, atomics:new(1, [])),
  ok.

%% Reset to a clean-but-initialized state. Called from the registry's full
%% reset, which sweeps every instrument-owned persistent_term key, including
%% instrument_family_seq, so the seq counter is re-minted here.
-spec reset() -> ok.
reset() ->
  lists:foreach(fun(T) ->
    case ets:info(T, name) of
      undefined -> ok;
      _ -> ets:delete_all_objects(T)
    end
  end, [?TAB, ?FREE]),
  persistent_term:put(instrument_family_seq, atomics:new(1, [])),
  ok.

%% During unregister_all the seq key is briefly absent; wait for reset/0.
family_seq() ->
  family_seq(50).

family_seq(0) ->
  error(instrument_series_not_initialized);
family_seq(N) ->
  case persistent_term:get(instrument_family_seq, undefined) of
    undefined ->
      erlang:yield(),
      family_seq(N - 1);
    Ref ->
      Ref
  end.

%% ============================================================================
%% Families
%% ============================================================================

%% Create-or-get a family. Duplicate create returns the existing meta without
%% a kind check.
-spec ensure_family(term(), atom(), binary(), [term()] | undefined,
                    [number()] | undefined) -> #family{}.
ensure_family(Name, Kind, Help, DeclaredLabels, Boundaries) ->
  %% Repeated creates are common (new_counter/2 per request): a fully
  %% published family returns before taking a family index. Otherwise
  %% create_family/5 also repairs a creator that died before publishing.
  case persistent_term:get({instrument_family, Name}, undefined) of
    #family{} = Existing -> Existing;
    _ -> create_family(Name, Kind, Help, DeclaredLabels, Boundaries)
  end.

create_family(Name, Kind, Help, DeclaredLabels, Boundaries) ->
  FamSeq = family_seq(),
  Counters = atomics:new(4, [{signed, true}]),
  %% slot 1 is reserved for the unlabeled series
  atomics:put(Counters, ?HW, 1),
  Meta = #family{
    kind = Kind,
    help = Help,
    declared_labels = DeclaredLabels,
    boundaries = Boundaries,
    start_time = erlang:system_time(nanosecond),
    idx = atomics:add_get(FamSeq, 1, 1),
    inc = erlang:unique_integer([positive]),
    counters = Counters,
    chunk0 = mint_chunk(Kind, Boundaries, 0)
  },
  case ets:insert_new(?TAB, {{Name, family}, Meta}) of
    true ->
      publish_family(Name, Meta),
      Meta;
    false ->
      case ets:lookup_element(?TAB, {Name, family}, 2, undefined) of
        undefined ->
          %% concurrent teardown deleted the arbiter row; the claim is free again
          create_family(Name, Kind, Help, DeclaredLabels, Boundaries);
        Existing ->
          %% dead-creator repair: complete a missing publication
          case persistent_term:get({instrument_family, Name}, undefined) of
            undefined -> publish_family(Name, Existing);
            _ -> ok
          end,
          Existing
      end
  end.

%% Custom family (instrument_metric:register/1 compat). The payload is a
%% collect MFA or {raw, #metric{}} (a record registered with no collector).
-spec ensure_custom(term(), {module(), atom(), list()} | {raw, #metric{}}) ->
        ok | {error, already_exists}.
ensure_custom(Name, Payload) ->
  FamSeq = family_seq(),
  Meta = {custom, Payload, atomics:add_get(FamSeq, 1, 1)},
  case ets:insert_new(?TAB, {{Name, family}, Meta}) of
    true ->
      publish_family(Name, Meta),
      ok;
    false ->
      {error, already_exists}
  end.

publish_family(Name, #family{idx = Idx} = Meta) ->
  persistent_term:put({instrument_family_idx, Idx}, Name),
  persistent_term:put({instrument_family, Name}, Meta),
  ok;
publish_family(Name, {custom, _, Idx} = Meta) ->
  persistent_term:put({instrument_family_idx, Idx}, Name),
  persistent_term:put({instrument_family, Name}, Meta),
  ok.

-type custom_payload() :: {module(), atom(), list()} | {raw, #metric{}}.

%% Family lookup: pt fast path, arbiter-row fallback (degraded mode after a
%% creator died mid-publication).
-spec family(term()) -> #family{} | {custom, custom_payload(), pos_integer()} | undefined.
family(Name) ->
  case persistent_term:get({instrument_family, Name}, undefined) of
    undefined ->
      try ets:lookup_element(?TAB, {Name, family}, 2)
      catch error:badarg -> undefined
      end;
    Meta ->
      Meta
  end.

%% The family currently registered under Name is still incarnation Inc.
same_incarnation(Name, Inc) ->
  case ets:lookup_element(?TAB, {Name, family}, 2, undefined) of
    #family{inc = Inc} -> true;
    _ -> false
  end.

%% ============================================================================
%% Chunks and slots
%% ============================================================================

chunk_size(C) -> min(?FIRST_CHUNK bsl C, ?MAX_CHUNK).

%% Slots before chunk C: 16 * (2^C - 1) while chunks double, then 1024 each.
-define(DOUBLING_CHUNKS, 7).                %% chunks 0..6 double: 16..1024
-define(SLOTS_BEFORE_FLAT, 2032).           %% 16 * (2^7 - 1)

%% Slot S -> {Chunk, Index in chunk}.
slot_loc(S) when S =< ?SLOTS_BEFORE_FLAT ->
  C = doubling_chunk(S, 0),
  {C, S - ?FIRST_CHUNK * ((1 bsl C) - 1)};
slot_loc(S) ->
  Off = S - ?SLOTS_BEFORE_FLAT - 1,
  {?DOUBLING_CHUNKS + Off div ?MAX_CHUNK, Off rem ?MAX_CHUNK + 1}.

doubling_chunk(S, C) ->
  case S =< ?FIRST_CHUNK * ((2 bsl C) - 1) of
    true -> C;
    false -> doubling_chunk(S, C + 1)
  end.

mint_chunk(Kind, Bounds, C) ->
  Size = chunk_size(C),
  {atomics:new(Size, []), list_to_tuple([mint_cell(Kind, Bounds) || _ <- lists:seq(1, Size)])}.

mint_cell(counter, _Bounds) ->
  {ok, Ref} = instrument_nif:new_gauge(),
  #metric{name = series, handle = {Ref, erlang:system_time(nanosecond)}};
mint_cell(histogram, Bounds0) ->
  Bounds = case Bounds0 of
             undefined -> instrument_histogram:default_buckets();
             _ -> Bounds0
           end,
  #metric{name = series, handle = instrument_histogram:mint_cell(Bounds)};
mint_cell(_GaugeLike, _Bounds) ->
  {ok, Ref} = instrument_nif:new_gauge(),
  #metric{name = series, handle = Ref}.

reset_cell(histogram, Row) ->
  instrument_histogram:reset_cell(Row);
reset_cell(counter, #metric{handle = {Ref, _}}) ->
  instrument_nif:set_gauge(Ref, 0.0);
reset_cell(_GaugeLike, #metric{handle = Ref}) ->
  instrument_nif:set_gauge(Ref, 0.0).

%% The chunk if it is published (pt) or at least claimed (ETS), else undefined.
chunk(_Name, #family{chunk0 = Chunk0}, 0) ->
  Chunk0;
chunk(Name, #family{inc = Inc}, C) ->
  case persistent_term:get({instrument_chunk, Name, Inc, C}, undefined) of
    undefined ->
      case ets:lookup(?TAB, {'$s', Inc, chunk, C}) of
        [{_, Chunk, Publisher}] ->
          repair_chunk(Name, Inc, C, Chunk, Publisher),
          Chunk;
        [] ->
          undefined
      end;
    Chunk ->
      Chunk
  end.

%% A publisher that died between claiming a chunk and publishing it leaves it
%% in ETS only. One repairer publishes it; the key is still fresh.
repair_chunk(Name, Inc, C, Chunk, Publisher) ->
  case Publisher =/= self() andalso not is_process_alive(Publisher)
       andalso ets:insert_new(?TAB, {{'$s', Inc, repair, C}, true, nil}) of
    true -> persistent_term:put({instrument_chunk, Name, Inc, C}, Chunk);
    false -> ok
  end.

%% @doc Makes sure chunk C of the family exists. Any writer that needs a
%% missing chunk creates one; ets:insert_new picks the single one that is
%% published, the others are dropped. Nobody waits for another process.
-spec ensure_chunk(term(), #family{}, non_neg_integer()) ->
        {atomics:atomics_ref(), tuple()} | undefined.
ensure_chunk(Name, #family{} = Fam, C) ->
  case chunk(Name, Fam, C) of
    undefined -> publish_chunk(Name, Fam, C);
    Chunk -> Chunk
  end.

publish_chunk(Name, #family{inc = Inc, kind = Kind, boundaries = Bounds}, C) ->
  Chunk = mint_chunk(Kind, Bounds, C),
  case ets:insert_new(?TAB, {{'$s', Inc, chunk, C}, Chunk, self()}) of
    true ->
      persistent_term:put({instrument_chunk, Name, Inc, C}, Chunk),
      %% A teardown that ran meanwhile cannot have seen this key.
      case same_incarnation(Name, Inc) of
        true -> Chunk;
        false ->
          persistent_term:erase({instrument_chunk, Name, Inc, C}),
          ets:delete(?TAB, {'$s', Inc, chunk, C}),
          undefined
      end;
    false ->
      case ets:lookup(?TAB, {'$s', Inc, chunk, C}) of
        [{_, Winner, _}] -> Winner;
        [] -> undefined
      end
  end.

%% {Epochs, Ix, Row} for slot S, creating its chunk if needed.
slot_ref(Name, Fam, S) ->
  {C, Ix} = slot_loc(S),
  case ensure_chunk(Name, Fam, C) of
    {Epochs, Rows} -> {Epochs, Ix, element(Ix, Rows)};
    undefined -> undefined
  end.

%% Retire a slot: odd (live) -> even; even (pending) -> +2, which makes an
%% in-flight claim's compare-exchange fail. Returns the previous epoch.
retire(Epochs, Ix) ->
  E = atomics:get(Epochs, Ix),
  New = case E band 1 of 1 -> E + 1; 0 -> E + 2 end,
  case atomics:compare_exchange(Epochs, Ix, E, New) of
    ok -> E;
    _ -> retire(Epochs, Ix)
  end.

%% ============================================================================
%% Writes
%% ============================================================================

%% The unified write path. CacheKey is the API's natural input shape (meter:
%% Canon; vec API: raw values list). CanonFun computes the canonical
%% {SortedNames, Values} only on a miss.
-spec write(term(), term(), fun(() -> {list(), list()}),
            fun((#metric{}) -> any())) -> any().
write(Name, CacheKey, CanonFun, WriteFun) ->
  case erlang:get({?PD, Name, CacheKey}) of
    {Epochs, Ix, E, Row} ->
      case atomics:get(Epochs, Ix) of
        E -> WriteFun(Row);
        _ -> miss(Name, CacheKey, CanonFun, WriteFun)
      end;
    _ ->
      miss(Name, CacheKey, CanonFun, WriteFun)
  end.

%% Unlabeled (no-attribute) write: slot 1 of chunk 0, read from the family
%% meta, so the hot path is one persistent_term get and one atomics read.
-spec write_unlabeled(term(), atom(), number()) -> any().
write_unlabeled(Name, Kind, Value) ->
  case persistent_term:get({instrument_family, Name}, undefined) of
    #family{chunk0 = {Epochs, Rows}} ->
      case atomics:get(Epochs, 1) band 1 of
        1 -> apply_unlabeled(Kind, element(1, Rows), Value);
        0 -> miss(Name, ?UNLABELED, fun() -> ?UNLABELED end,
                  fun(R) -> apply_unlabeled(Kind, R, Value) end)
      end;
    _ ->
      miss(Name, ?UNLABELED, fun() -> ?UNLABELED end,
           fun(R) -> apply_unlabeled(Kind, R, Value) end)
  end.

apply_unlabeled(counter, Row, V)                     -> instrument_counter:inc_counter(Row, V);
apply_unlabeled(up_down_counter, Row, V) when V >= 0 -> instrument_gauge:inc_gauge(Row, V);
apply_unlabeled(up_down_counter, Row, V)             -> instrument_gauge:dec_gauge(Row, -V);
apply_unlabeled(gauge, Row, V)                       -> instrument_gauge:set_gauge(Row, V);
apply_unlabeled(histogram, Row, V)                   -> instrument_histogram:observe_histogram(Row, V).

%% Cache miss: resolve the label set through ETS, else create its series.
miss(Name, CacheKey, CanonFun, WriteFun) ->
  case family(Name) of
    #family{inc = Inc} = Fam ->
      case ets:lookup_element(?TAB, {'$s', Inc, key, CacheKey}, 2, undefined) of
        S when is_integer(S) ->
          case live_ref(Name, Fam, S) of
            {Epochs, Ix, E, Row} ->
              cache(Name, CacheKey, Epochs, Ix, E, Row),
              WriteFun(Row);
            not_live ->
              by_canon(Name, Fam, CacheKey, CanonFun, WriteFun)
          end;
        undefined ->
          by_canon(Name, Fam, CacheKey, CanonFun, WriteFun)
      end;
    _ ->
      {error, not_found}
  end.

live_ref(Name, Fam, S) ->
  case slot_ref(Name, Fam, S) of
    {Epochs, Ix, Row} ->
      E = atomics:get(Epochs, Ix),
      case E band 1 of
        1 -> {Epochs, Ix, E, Row};
        0 -> not_live
      end;
    undefined ->
      not_live
  end.

by_canon(Name, #family{inc = Inc} = Fam, CacheKey, CanonFun, WriteFun) ->
  Canon = CanonFun(),
  case valid_canon(Fam, Canon) of
    false ->
      {error, invalid_labels};
    true ->
      case ets:lookup_element(?TAB, {'$s', Inc, canon, Canon}, 2, undefined) of
        S when is_integer(S) ->
          %% Another cache key (or a claim in progress) already holds this
          %% label set: share its series.
          Cacheable = adopt_key(Fam, CacheKey, S),
          case live_ref(Name, Fam, S) of
            {Epochs, Ix, E, Row} ->
              _ = Cacheable andalso cache(Name, CacheKey, Epochs, Ix, E, Row),
              WriteFun(Row);
            not_live ->
              complete_claim(Name, Fam, S, Canon, CacheKey, WriteFun)
          end;
        undefined ->
          case over_limit(Fam, Canon) of
            true -> overflow_write(Name, Fam, WriteFun);
            false -> claim(Name, Fam, Canon, CacheKey, WriteFun)
          end
      end
  end.

%% A degenerate sentinel {[], [_|_]} comes from a vec arity mismatch; names
%% must arrive sorted (scrape unions depend on it).
valid_canon(#family{declared_labels = Declared}, {Names, Values}) ->
  ArityOk = case Declared of
              undefined -> true;
              _ -> length(Names) =:= length(Declared)
            end,
  ArityOk andalso not (Names =:= [] andalso Values =/= [])
    andalso Names =:= lists:sort(Names);
valid_canon(_Fam, _Canon) ->
  false.

over_limit(#family{counters = Counters}, Canon) ->
  overflow_canon_marker(Canon) =:= not_overflow andalso
    atomics:get(Counters, ?LIVE) >= instrument_config:get_metric_cardinality_limit().

%% An overflow canon is exempt from the cap (it must be creatable at the cap).
overflow_canon_marker({[?OVERFLOW_VALUE], [<<"true">>]}) ->
  overflow;
overflow_canon_marker({_Names, Values} = Canon) ->
  case Values =/= [] andalso lists:all(fun(V) -> V =:= ?OVERFLOW_VALUE end, Values) of
    true -> Canon;
    false -> not_overflow
  end;
overflow_canon_marker(_) ->
  not_overflow.

overflow_write(Name, #family{declared_labels = Declared, counters = Counters}, WriteFun) ->
  atomics:add(Counters, ?DROPPED, 1),
  Canon = overflow_canon(Declared),
  write(Name, Canon, fun() -> Canon end, WriteFun).

overflow_canon(undefined) ->
  {[?OVERFLOW_VALUE], [<<"true">>]};
overflow_canon(Declared) ->
  Sorted = lists:sort(Declared),
  {Sorted, [?OVERFLOW_VALUE || _ <- Sorted]}.

%% Record CacheKey as another key of series S. Distinct raw values that
%% canonicalize alike (floats past the 6th decimal, strings vs binaries) are
%% capped at the cardinality limit per family; past it, writes still reach the
%% right series through this slower path. Returns whether the key may be
%% cached in the process dictionary.
adopt_key(#family{inc = Inc, counters = Counters}, CacheKey, S) ->
  Key = {'$s', Inc, key, CacheKey},
  case ets:lookup_element(?TAB, Key, 2, undefined) of
    S -> true;
    _ ->
      Limit = instrument_config:get_metric_cardinality_limit(),
      case atomics:add_get(Counters, ?ALIASES, 1) =< Limit
           andalso ets:insert_new(?TAB, {Key, S, alias}) of
        true -> true;
        false ->
          atomics:sub(Counters, ?ALIASES, 1),
          false
      end
  end.

%% First write of a label set: take a slot, claim the canon, publish.
claim(Name, #family{inc = Inc} = Fam, Canon, CacheKey, WriteFun) ->
  case take_slot(Name, Fam, Canon) of
    {ok, S} ->
      case ets:insert_new(?TAB, {{'$s', Inc, canon, Canon}, S, nil}) of
        true ->
          complete_claim(Name, Fam, S, Canon, CacheKey, WriteFun);
        false ->
          %% Lost to a concurrent claim of the same label set.
          release_unused(Fam, S),
          by_canon(Name, Fam, CacheKey, fun() -> Canon end, WriteFun)
      end;
    error ->
      {error, not_found}
  end.

%% Finish a claim (or help one whose claimer died): record the slot's labels
%% and key, check the family is still this incarnation, then make the slot
%% live. Only the compare-exchange winner counts the series.
complete_claim(Name, #family{inc = Inc, counters = Counters} = Fam, S, Canon, CacheKey, WriteFun) ->
  case slot_ref(Name, Fam, S) of
    undefined ->
      {error, not_found};
    {Epochs, Ix, Row} ->
      E0 = atomics:get(Epochs, Ix),
      _ = ets:insert_new(?TAB, {{'$s', Inc, slot, S}, Canon, CacheKey}),
      _ = ets:insert_new(?TAB, {{'$s', Inc, key, CacheKey}, S, own}),
      instrument_histogram:activate_exemplars(Row),
      case same_incarnation(Name, Inc) of
        false ->
          undo_claim(Inc, S, Canon, CacheKey, Row),
          {error, not_found};
        true when E0 band 1 =:= 1 ->
          cache_if_keyed(Name, Inc, CacheKey, S, Epochs, Ix, E0, Row),
          WriteFun(Row);
        true ->
          case atomics:compare_exchange(Epochs, Ix, E0, E0 + 1) of
            ok ->
              %% A removal that deleted the canon meanwhile wins: retire again.
              case ets:lookup_element(?TAB, {'$s', Inc, canon, Canon}, 2, undefined) of
                S ->
                  case overflow_canon_marker(Canon) of
                    not_overflow -> atomics:add(Counters, ?LIVE, 1);
                    _ -> ok
                  end,
                  cache_if_keyed(Name, Inc, CacheKey, S, Epochs, Ix, E0 + 1, Row),
                  WriteFun(Row);
                _ ->
                  _ = retire(Epochs, Ix),
                  ok
              end;
            _ ->
              E1 = atomics:get(Epochs, Ix),
              case E1 =:= E0 + 1 of
                true ->
                  %% A helper completed it.
                  cache_if_keyed(Name, Inc, CacheKey, S, Epochs, Ix, E1, Row),
                  WriteFun(Row);
                false ->
                  %% Removed or torn down while claiming; the write is dropped.
                  ok
              end
          end
      end
  end.

undo_claim(Inc, S, Canon, CacheKey, Row) ->
  ets:delete(?TAB, {'$s', Inc, canon, Canon}),
  ets:delete(?TAB, {'$s', Inc, slot, S}),
  ets:delete(?TAB, {'$s', Inc, key, CacheKey}),
  instrument_histogram:cleanup(Row).

cache_if_keyed(Name, Inc, CacheKey, S, Epochs, Ix, E, Row) ->
  case ets:lookup_element(?TAB, {'$s', Inc, key, CacheKey}, 2, undefined) of
    S -> cache(Name, CacheKey, Epochs, Ix, E, Row);
    _ -> ok
  end.

%% Slot 1 holds the unlabeled series. Others come from the free list (past
%% quarantine, cell reset) or from the high-water mark.
take_slot(_Name, _Fam, ?UNLABELED) ->
  {ok, 1};
take_slot(Name, #family{inc = Inc, kind = Kind, counters = Counters} = Fam, _Canon) ->
  case take_free(Inc) of
    {ok, S} ->
      case slot_ref(Name, Fam, S) of
        {_Epochs, _Ix, Row} -> reset_cell(Kind, Row), {ok, S};
        undefined -> error
      end;
    none ->
      S = atomics:add_get(Counters, ?HW, 1),
      {C, Ix} = slot_loc(S),
      case ensure_chunk(Name, Fam, C) of
        undefined ->
          error;
        _ ->
          %% Halfway through a chunk, have the next one created ahead.
          case Ix =:= chunk_size(C) div 2 of
            true -> gen_server:cast(instrument_registry, {prepare_chunk, Name, Inc, C + 1});
            false -> ok
          end,
          {ok, S}
      end
  end.

take_free(Inc) ->
  Cutoff = erlang:monotonic_time(millisecond) - quarantine_ms(),
  case ets:select(?FREE, [{{{Inc, '$1', '_'}}, [{'=<', '$1', Cutoff}], ['$_']}], 1) of
    {[{Key}], _} ->
      case ets:take(?FREE, Key) of
        [_] ->
          {Inc, _, S} = Key,
          case ets:member(?TAB, {'$s', Inc, pin, S}) of
            true -> take_free(Inc);
            false -> {ok, S}
          end;
        [] ->
          take_free(Inc)
      end;
    _ ->
      none
  end.

quarantine_ms() ->
  case application:get_env(instrument, series_reuse_quarantine_ms) of
    {ok, Ms} when is_integer(Ms), Ms >= 0 -> Ms;
    _ -> 5000
  end.

%% A slot taken but not used (lost claim) can be reused immediately.
release_unused(_Fam, 1) ->
  ok;
release_unused(#family{inc = Inc}, S) ->
  ets:insert(?FREE, {{Inc, erlang:monotonic_time(millisecond) - quarantine_ms(), S}}),
  ok.

%% ============================================================================
%% Process-dictionary cache
%% ============================================================================

cache(Name, CacheKey, Epochs, Ix, E, Row) ->
  case put({?PD, Name, CacheKey}, {Epochs, Ix, E, Row}) of
    undefined -> count_entry();
    _ -> ok
  end,
  ok.

%% Bound stale entries: every so often drop entries whose slot moved on, and
%% raise the threshold when most entries are still valid.
count_entry() ->
  N = case get(?PD_COUNT) of undefined -> 1; C -> C + 1 end,
  Limit = case get(?PD_LIMIT) of undefined -> ?PD_SWEEP; L -> L end,
  case N >= Limit of
    true ->
      Kept = sweep_cache(),
      put(?PD_COUNT, 0),
      case Kept * 2 > Limit of
        true -> put(?PD_LIMIT, Limit * 2);
        false -> ok
      end;
    false ->
      put(?PD_COUNT, N)
  end.

sweep_cache() ->
  lists:foldl(fun({{?PD, _, _} = K, {Epochs, Ix, E, _}}, Kept) ->
                    case atomics:get(Epochs, Ix) of
                      E -> Kept + 1;
                      _ -> erase(K), Kept
                    end;
                 (_, Kept) -> Kept
              end, 0, get()).

%% @doc Drops this process's cached series entries.
-spec purge_cache() -> ok.
purge_cache() ->
  _ = [erase(K) || {{?PD, _, _} = K, _} <- get()],
  erase(?PD_COUNT),
  erase(?PD_LIMIT),
  ok.

%% ============================================================================
%% Handles and lookups
%% ============================================================================

%% @doc Resolves (creating if needed) the cell of a label set for use as a
%% handle. The cell escapes the epoch check, so its slot is pinned: it is
%% never reused for another label set.
-spec resolve_row(term(), term(), fun(() -> {list(), list()})) -> #metric{} | {error, term()}.
resolve_row(Name, CacheKey, CanonFun) ->
  case write(Name, CacheKey, CanonFun, fun(R) -> R end) of
    #metric{} = Row ->
      case family(Name) of
        #family{inc = Inc} ->
          case ets:lookup_element(?TAB, {'$s', Inc, key, CacheKey}, 2, undefined) of
            S when is_integer(S) -> ets:insert(?TAB, {{'$s', Inc, pin, S}, true, nil});
            _ -> ok
          end,
          Row;
        _ ->
          {error, not_found}
      end;
    ok ->
      {error, not_found};
    Other ->
      Other
  end.

%% @doc The live unlabeled cell of a family, without creating it.
-spec unlabeled_row(term()) -> #metric{} | {error, not_found}.
unlabeled_row(Name) ->
  case family(Name) of
    #family{chunk0 = {Epochs, Rows}} ->
      case atomics:get(Epochs, 1) band 1 of
        1 -> element(1, Rows);
        0 -> {error, not_found}
      end;
    _ ->
      {error, not_found}
  end.

%% @doc The overflow series' cell, once the cardinality cap was hit.
-spec overflow_row(term()) -> #metric{} | undefined.
overflow_row(Name) ->
  case family(Name) of
    #family{inc = Inc, declared_labels = Declared} = Fam ->
      case ets:lookup_element(?TAB, {'$s', Inc, canon, overflow_canon(Declared)}, 2, undefined) of
        S when is_integer(S) ->
          case live_ref(Name, Fam, S) of
            {_, _, _, Row} -> Row;
            not_live -> undefined
          end;
        undefined ->
          undefined
      end;
    _ ->
      undefined
  end.

%% @doc Folds the live series of a family in slot order:
%% `Fun(CacheKey, Canon, Row, Acc)'.
-spec fold_rows(term(), fun((term(), {list(), list()}, #metric{}, term()) -> term())) -> term().
fold_rows(Name, Fun) ->
  fold_rows(Name, Fun, []).

fold_rows(Name, Fun, Acc0) ->
  case family(Name) of
    #family{inc = Inc, counters = Counters} = Fam ->
      HW = atomics:get(Counters, ?HW),
      {Acc, _} = lists:foldl(fun(S, {Acc1, Chunks}) ->
        {C, Ix} = slot_loc(S),
        {Chunk, Chunks1} = cached_chunk(Name, Fam, C, Chunks),
        case Chunk of
          {Epochs, Rows} ->
            E = atomics:get(Epochs, Ix),
            case E band 1 of
              1 ->
                case ets:lookup(?TAB, {'$s', Inc, slot, S}) of
                  [{_, Canon, CacheKey}] ->
                    {Fun(CacheKey, Canon, element(Ix, Rows), Acc1), Chunks1};
                  [] ->
                    {Acc1, Chunks1}
                end;
              0 ->
                {Acc1, Chunks1}
            end;
          undefined ->
            {Acc1, Chunks1}
        end
      end, {Acc0, #{}}, lists:seq(1, HW)),
      Acc;
    _ ->
      Acc0
  end.

cached_chunk(Name, Fam, C, Chunks) ->
  case Chunks of
    #{C := Chunk} -> {Chunk, Chunks};
    _ ->
      Chunk = chunk(Name, Fam, C),
      {Chunk, Chunks#{C => Chunk}}
  end.

%% @doc Live label sets of a family (cardinality cap accounting).
-spec live_count(term()) -> non_neg_integer().
live_count(Name) ->
  case family(Name) of
    #family{counters = Counters} -> max(0, atomics:get(Counters, ?LIVE));
    _ -> 0
  end.

%% @doc Writes routed to the overflow series since the family was created.
-spec dropped(term()) -> non_neg_integer().
dropped(Name) ->
  case family(Name) of
    #family{counters = Counters} -> atomics:get(Counters, ?DROPPED);
    _ -> 0
  end.

%% Test helpers.
slot_of(Name, CacheKey) ->
  case family(Name) of
    #family{inc = Inc} -> ets:lookup_element(?TAB, {'$s', Inc, key, CacheKey}, 2, undefined);
    _ -> undefined
  end.

high_water(Name) ->
  case family(Name) of
    #family{counters = Counters} -> atomics:get(Counters, ?HW);
    _ -> 0
  end.

%% ============================================================================
%% Collection
%% ============================================================================

%% Families are walked through the family chain in persistent_term; each
%% family's live slots are read from its chunks, with labels from ETS.
-spec collect_all() -> [map()].
collect_all() ->
  case persistent_term:get(instrument_family_seq, undefined) of
    undefined -> [];
    FamSeq -> collect_all(FamSeq)
  end.

collect_all(FamSeq) ->
  N = atomics:get(FamSeq, 1),
  lists:reverse(lists:foldl(fun(K, Acc) ->
    case persistent_term:get({instrument_family_idx, K}, undefined) of
      undefined -> Acc;
      Name ->
        case persistent_term:get({instrument_family, Name}, undefined) of
          undefined -> Acc;
          {custom, {raw, _Metric}, _Idx} ->
            Acc;
          {custom, {M, F, A}, _Idx} ->
            try [erlang:apply(M, F, A) | Acc]
            catch Class:Reason:Stacktrace ->
              logger:warning("Metric collector ~p:~p failed: ~p:~p",
                             [M, F, Class, Reason],
                             #{mfa => {M, F, length(A)}, stacktrace => Stacktrace}),
              Acc
            end;
          #family{} = Fam ->
            %% One unreadable family must not fail the whole scrape.
            try collect_family(Name, Fam) of
              empty -> Acc;
              Entry -> [Entry | Acc]
            catch Class:Reason:Stacktrace ->
              logger:warning("Skipping metric ~p in collection: ~p:~p",
                             [Name, Class, Reason], #{stacktrace => Stacktrace}),
              Acc
            end
        end
    end
  end, [], lists:seq(1, N))).

collect_family(Name, #family{kind = Kind, help = Help, start_time = T0,
                             declared_labels = Declared}) ->
  {Data, Union0} = fold_rows(Name, fun(_CacheKey, {Names, Values}, Row, {DataAcc, UnionAcc}) ->
    {[{Names, Values, read_row(Kind, Row)} | DataAcc], lists:umerge(UnionAcc, Names)}
  end, {[], []}),
  case Data of
    [] -> empty;
    _ ->
      Union = case Declared of
        undefined -> Union0;
        _ -> lists:sort(Declared)
      end,
      #{name => Name, help => Help, type => wire_type(Kind),
        start_time => T0, labels => Union, data => lists:reverse(Data)}
  end.

read_row(counter, Row) -> instrument_counter:get_counter(Row);
read_row(histogram, Row) -> instrument_histogram:get_histogram(Row);
read_row(_GaugeLike, Row) -> instrument_gauge:get_gauge(Row).

wire_type(observable_counter) -> counter;
wire_type(up_down_counter) -> gauge;
wire_type(observable_gauge) -> gauge;
wire_type(observable_up_down_counter) -> gauge;
wire_type(K) -> K.

%% ============================================================================
%% Removal and teardown (admin-time, serialized by the registry)
%% ============================================================================

%% @doc Removes the series a cache key (own key or alias) belongs to.
-spec remove_row(term(), term()) -> ok.
remove_row(Name, CacheKey) ->
  case family(Name) of
    #family{inc = Inc} = Fam ->
      case ets:lookup_element(?TAB, {'$s', Inc, key, CacheKey}, 2, undefined) of
        S when is_integer(S) -> remove_slot(Name, Fam, S);
        undefined -> ok
      end;
    _ ->
      ok
  end.

%% @doc Removes every series of a family; the family itself stays.
-spec clear_family_rows(term()) -> ok.
clear_family_rows(Name) ->
  case family(Name) of
    #family{inc = Inc} = Fam ->
      Slots = ets:select(?TAB, [{{{'$s', Inc, slot, '$1'}, '_', '_'}, [], ['$1']}]),
      lists:foreach(fun(S) -> remove_slot(Name, Fam, S) end, Slots),
      ok;
    _ ->
      ok
  end.

%% Delete the canon first (so no helper completes it again), retire the
%% epoch, drop the keys, then free the slot for reuse after quarantine.
remove_slot(Name, #family{inc = Inc, kind = Kind, counters = Counters} = Fam, S) ->
  case ets:lookup(?TAB, {'$s', Inc, slot, S}) of
    [{_, Canon, _CacheKey}] ->
      ets:delete(?TAB, {'$s', Inc, canon, Canon}),
      case slot_ref(Name, Fam, S) of
        {Epochs, Ix, Row} ->
          Old = retire(Epochs, Ix),
          case Old band 1 =:= 1 andalso overflow_canon_marker(Canon) =:= not_overflow of
            true -> atomics:sub(Counters, ?LIVE, 1);
            false -> ok
          end,
          instrument_histogram:cleanup(Row),
          %% Slot 1 is never reused for another label set: reset in place.
          _ = S =:= 1 andalso reset_cell(Kind, Row),
          ok;
        undefined ->
          ok
      end,
      Keys = ets:select(?TAB, [{{{'$s', Inc, key, '$1'}, S, '$2'}, [], [{{'$1', '$2'}}]}]),
      lists:foreach(fun({K, Type}) ->
        ets:delete(?TAB, {'$s', Inc, key, K}),
        _ = Type =:= alias andalso atomics:sub(Counters, ?ALIASES, 1),
        ok
      end, Keys),
      ets:delete(?TAB, {'$s', Inc, slot, S}),
      case S =/= 1 andalso not ets:member(?TAB, {'$s', Inc, pin, S}) of
        true -> ets:insert(?FREE, {{Inc, erlang:monotonic_time(millisecond), S}});
        false -> ok
      end,
      ok;
    [] ->
      ok
  end.

%% @doc Full family teardown: unpublish the family first (in-flight claims
%% then fail their incarnation check), retire every slot, drop the chunks and
%% the family's rows.
-spec teardown_family(term()) -> ok.
teardown_family(Name) ->
  case family(Name) of
    #family{idx = Idx, inc = Inc, counters = Counters} = Fam ->
      ets:delete(?TAB, {Name, family}),
      persistent_term:erase({instrument_family, Name}),
      Published = ets:select(?TAB, [{{{'$s', Inc, chunk, '$1'}, '_', '_'}, [], ['$1']}]),
      {LastC, _} = slot_loc(max(1, atomics:get(Counters, ?HW))),
      Chunks = lists:usort([0 | Published] ++ lists:seq(0, LastC)),
      lists:foreach(fun(C) ->
        case chunk(Name, Fam, C) of
          {_, _} = Chunk -> kill_chunk(Chunk);
          undefined -> ok
        end,
        _ = C > 0 andalso persistent_term:erase({instrument_chunk, Name, Inc, C}),
        ok
      end, Chunks),
      persistent_term:erase({instrument_family_idx, Idx}),
      ets:select_delete(?TAB, [{{{'$s', Inc, '_', '_'}, '_', '_'}, [], [true]}]),
      ets:select_delete(?FREE, [{{{Inc, '_', '_'}}, [], [true]}]),
      ok;
    {custom, _, Idx} ->
      ets:delete(?TAB, {Name, family}),
      persistent_term:erase({instrument_family, Name}),
      persistent_term:erase({instrument_family_idx, Idx}),
      ok;
    undefined ->
      ok
  end.

%% Retire every slot of a chunk and release histogram reservoirs.
kill_chunk({Epochs, Rows}) ->
  lists:foreach(fun(Ix) ->
    _ = retire(Epochs, Ix),
    instrument_histogram:cleanup(element(Ix, Rows))
  end, lists:seq(1, tuple_size(Rows))).

%% @doc Retires the slots held by a family meta or chunk value about to be
%% erased by the registry's sweep, so processes that cached them stop writing
%% into cells that are no longer exported.
-spec kill_term(term()) -> ok.
kill_term(#family{chunk0 = Chunk0}) ->
  kill_chunk(Chunk0);
kill_term({Epochs, Rows} = Chunk) when is_tuple(Rows) ->
  try atomics:info(Epochs) of
    _ -> kill_chunk(Chunk)
  catch _:_ -> ok
  end;
kill_term(_) ->
  ok.

%% ============================================================================
%% Label canonicalization (shared by the meter, simple-metric, and vec APIs).
%% ============================================================================

%% Stringify a label value for the wire. One definition for all three APIs.
-spec to_label_value(term()) -> binary().
to_label_value(V) when is_binary(V)  -> V;
to_label_value(V) when is_atom(V)    -> atom_to_binary(V, utf8);
to_label_value(V) when is_integer(V) -> integer_to_binary(V);
to_label_value(V) when is_float(V)   -> float_to_binary(V, [{decimals, 6}, compact]);
to_label_value(V) when is_list(V) ->
  %% Unicode strings and iolists; anything else is printed like other terms.
  try unicode:characters_to_binary(V) of
    B when is_binary(B) -> B;
    _ -> term_label(V)
  catch _:_ -> term_label(V)
  end;
to_label_value(V) ->
  %% Tuples (IP addresses), pids, refs, maps: a printed form instead of
  %% crashing the writer.
  term_label(V).

term_label(V) ->
  unicode:characters_to_binary(io_lib:format("~0tp", [V])).

%% Canonicalize a positional vec values list against the family's declared
%% names: sort by name, reorder values to match, stringify. On an arity
%% mismatch (or undefined declared labels) return the sentinel canon
%% {[], Values}, which valid_canon/2 rejects as {error, invalid_labels}.
-spec vec_canon([term()] | undefined, list()) -> {list(), list()}.
vec_canon(Declared, LabelValues)
    when is_list(Declared), length(Declared) =:= length(LabelValues) ->
  Pairs = lists:zip(Declared, LabelValues),
  Sorted = lists:keysort(1, Pairs),
  {[K || {K, _} <- Sorted], [to_label_value(V) || {_, V} <- Sorted]};
vec_canon(_Declared, LabelValues) ->
  {[], LabelValues}.
