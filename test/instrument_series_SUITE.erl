-module(instrument_series_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("../include/instrument.hrl").

-export([
  all/0,
  init_per_testcase/2,
  end_per_testcase/2,
  family_create_and_lookup/1,
  family_duplicate_create_returns_existing/1,
  family_arbiter_fallback/1,
  write_hot_and_first_touch/1,
  write_canon_normalization/1,
  concurrent_first_touch_single_winner/1,
  overflow_meter_canon/1,
  overflow_vec_canon/1,
  unlabeled_negative_updown/1,
  aliasing_adopts_existing_series/1,
  aliasing_at_cap_no_misroute/1,
  interrupted_claim_completed_by_next_writer/1,
  loser_after_winner_undo_returns_not_found/1,
  collect_families/1,
  collect_skips_removed_and_empty/1,
  collect_union_and_declared/1,
  teardown_returns_pt_to_baseline/1,
  %% chunked slots
  pt_keys_bounded_by_chunks/1,
  no_pt_replace_on_creation/1,
  stale_cached_writer_cannot_write_reused_slot/1,
  quarantine_keeps_removed_slot_unused/1,
  pinned_handle_slot_never_reused/1,
  dead_chunk_publisher_is_repaired/1,
  recreate_after_unregister_no_collision/1,
  app_restart_invalidates_cached_entries/1,
  cache_sweep_bounds_entries/1,
  reservoirs_only_for_live_series/1,
  slot_arithmetic/1
]).

all() ->
  [family_create_and_lookup,
   family_duplicate_create_returns_existing,
   family_arbiter_fallback,
   write_hot_and_first_touch,
   write_canon_normalization,
   concurrent_first_touch_single_winner,
   overflow_meter_canon,
   overflow_vec_canon,
   unlabeled_negative_updown,
   aliasing_adopts_existing_series,
   aliasing_at_cap_no_misroute,
   interrupted_claim_completed_by_next_writer,
   loser_after_winner_undo_returns_not_found,
   collect_families,
   collect_skips_removed_and_empty,
   collect_union_and_declared,
   teardown_returns_pt_to_baseline,
   pt_keys_bounded_by_chunks,
   no_pt_replace_on_creation,
   stale_cached_writer_cannot_write_reused_slot,
   quarantine_keeps_removed_slot_unused,
   pinned_handle_slot_never_reused,
   dead_chunk_publisher_is_repaired,
   recreate_after_unregister_no_collision,
   app_restart_invalidates_cached_entries,
   cache_sweep_bounds_entries,
   reservoirs_only_for_live_series,
   slot_arithmetic].

init_per_testcase(_TC, Config) ->
  application:stop(instrument),
  application:unset_env(instrument, series_reuse_quarantine_ms),
  instrument_series:purge_cache(),
  {ok, _} = application:ensure_all_started(instrument),
  Config.

end_per_testcase(_TC, _Config) ->
  application:stop(instrument),
  application:unset_env(instrument, series_reuse_quarantine_ms),
  os:unsetenv("OTEL_METRIC_CARDINALITY_LIMIT"),
  ok.

inc() -> fun(R) -> instrument_counter:inc_counter(R) end.
inc(N) -> fun(R) -> instrument_counter:inc_counter(R, N) end.
get_value() -> fun(R) -> instrument_counter:get_counter(R) end.

value(Name, CacheKey) ->
  instrument_series:write(Name, CacheKey, fun() -> error(no_such_series) end, get_value()).

%% ============================================================================
%% Families
%% ============================================================================

family_create_and_lookup(_Config) ->
  Meta = instrument_series:ensure_family(fam_a, counter, <<"help a">>, undefined, undefined),
  #family{kind = counter, help = <<"help a">>, idx = Idx, inc = Inc} = Meta,
  ?assert(is_integer(Idx)),
  ?assert(is_integer(Inc)),
  ?assertEqual(Meta, instrument_series:family(fam_a)),
  ?assertEqual(fam_a, persistent_term:get({instrument_family_idx, Idx})),
  ?assertEqual(1, instrument_series:high_water(fam_a)),
  ok.

family_duplicate_create_returns_existing(_Config) ->
  M1 = instrument_series:ensure_family(fam_b, counter, <<"h">>, undefined, undefined),
  M2 = instrument_series:ensure_family(fam_b, gauge, <<"other">>, undefined, undefined),
  ?assertEqual(M1, M2),
  ok.

family_arbiter_fallback(_Config) ->
  M = instrument_series:ensure_family(fam_c, gauge, <<"h">>, undefined, undefined),
  %% simulate a creator killed after claim, before publication
  persistent_term:erase({instrument_family, fam_c}),
  ?assertEqual(M, instrument_series:family(fam_c)),
  M = instrument_series:ensure_family(fam_c, gauge, <<"h">>, undefined, undefined),
  ?assertEqual(M, persistent_term:get({instrument_family, fam_c})),
  ok.

%% ============================================================================
%% Writes
%% ============================================================================

write_hot_and_first_touch(_Config) ->
  _ = instrument_series:ensure_family(w1, counter, <<>>, undefined, undefined),
  Canon = {[method], [<<"GET">>]},
  ok = instrument_series:write(w1, Canon, fun() -> Canon end, inc(2)),
  ok = instrument_series:write(w1, Canon, fun() -> Canon end, inc(2)),
  ?assertEqual(4.0, value(w1, Canon)),
  ?assertEqual(2, instrument_series:slot_of(w1, Canon)),
  ?assertEqual(1, instrument_registry:label_count(w1)),
  %% the second write is served from the process cache
  ?assertMatch({_, _, _, #metric{}}, get({'$instrument_series', w1, Canon})),
  ok.

write_canon_normalization(_Config) ->
  _ = instrument_series:ensure_family(w2, counter, <<>>, [method, status], undefined),
  CacheKey = [<<"GET">>, 200],
  Canon = instrument_series:vec_canon([method, status], CacheKey),
  ok = instrument_series:write(w2, CacheKey, fun() -> Canon end, inc()),
  [#{data := [{[method, status], [<<"GET">>, <<"200">>], 1.0}]}] =
    [E || #{name := w2} = E <- instrument_series:collect_all()],
  ok.

concurrent_first_touch_single_winner(_Config) ->
  _ = instrument_series:ensure_family(w3, counter, <<>>, undefined, undefined),
  Canon = {[k], [<<"v">>]},
  Parent = self(),
  Pids = [spawn_link(fun() ->
     ok = instrument_series:write(w3, Canon, fun() -> Canon end, inc()),
     Parent ! {done, self()}
   end) || _ <- lists:seq(1, 50)],
  [receive {done, P} -> ok end || P <- Pids],
  ?assertEqual(50.0, value(w3, Canon)),
  ?assertEqual(1, instrument_registry:label_count(w3)),
  [#{data := [_]}] = [E || #{name := w3} = E <- instrument_series:collect_all()],
  ok.

overflow_meter_canon(_Config) ->
  os:putenv("OTEL_METRIC_CARDINALITY_LIMIT", "3"),
  _ = instrument_series:ensure_family(w4, counter, <<>>, undefined, undefined),
  [ok = instrument_series:write(w4, {[i], [integer_to_binary(I)]},
         fun() -> {[i], [integer_to_binary(I)]} end, inc())
   || I <- lists:seq(1, 3)],
  ok = instrument_series:write(w4, {[i], [<<"over">>]},
         fun() -> {[i], [<<"over">>]} end, inc()),
  ?assertEqual(3, instrument_registry:label_count(w4)),
  ?assertEqual(1, instrument_registry:cardinality_dropped(w4)),
  OvRow = instrument_registry:overflow_sentinel(w4),
  ?assertEqual(1.0, instrument_counter:get_counter(OvRow)),
  ok.

overflow_vec_canon(_Config) ->
  os:putenv("OTEL_METRIC_CARDINALITY_LIMIT", "2"),
  _ = instrument_series:ensure_family(w5, counter, <<>>, [a, b], undefined),
  [ok = instrument_series:write(w5, [integer_to_binary(I), <<"x">>],
         fun() -> instrument_series:vec_canon([a, b], [integer_to_binary(I), <<"x">>]) end,
         inc()) || I <- lists:seq(1, 2)],
  ok = instrument_series:write(w5, [<<"over">>, <<"x">>],
         fun() -> instrument_series:vec_canon([a, b], [<<"over">>, <<"x">>]) end, inc()),
  ?assertNotEqual(undefined, instrument_registry:overflow_sentinel(w5)),
  ?assertEqual(1, instrument_registry:cardinality_dropped(w5)),
  ok.

unlabeled_negative_updown(_Config) ->
  _ = instrument_series:ensure_family(w6, up_down_counter, <<>>, undefined, undefined),
  ok = instrument_series:write_unlabeled(w6, up_down_counter, 5),
  ok = instrument_series:write_unlabeled(w6, up_down_counter, -2),
  ?assertEqual(3.0, instrument_gauge:get_gauge(instrument_series:unlabeled_row(w6))),
  ok.

aliasing_adopts_existing_series(_Config) ->
  _ = instrument_series:ensure_family(a1, counter, <<>>, [k], undefined),
  Canon = instrument_series:vec_canon([k], [200]),
  ok = instrument_series:write(a1, [200], fun() -> Canon end, inc()),
  ok = instrument_series:write(a1, [<<"200">>], fun() -> Canon end, inc()),
  ?assertEqual(instrument_series:slot_of(a1, [200]), instrument_series:slot_of(a1, [<<"200">>])),
  ?assertEqual(2.0, value(a1, [200])),
  ?assertEqual(1, instrument_registry:label_count(a1)),
  ok.

aliasing_at_cap_no_misroute(_Config) ->
  os:putenv("OTEL_METRIC_CARDINALITY_LIMIT", "3"),
  _ = instrument_series:ensure_family(a2, counter, <<>>, [k], undefined),
  Canon1 = instrument_series:vec_canon([k], [1]),
  ok = instrument_series:write(a2, [1], fun() -> Canon1 end, inc()),
  [ok = instrument_series:write(a2, [integer_to_binary(I)],
         fun() -> instrument_series:vec_canon([k], [integer_to_binary(I)]) end, inc())
   || I <- lists:seq(2, 3)],
  %% at the cap: an alias of an existing series is not routed to overflow
  ok = instrument_series:write(a2, [<<"1">>], fun() -> Canon1 end, inc()),
  ?assertEqual(2.0, value(a2, [1])),
  ?assertEqual(0, instrument_registry:cardinality_dropped(a2)),
  ok.

%% A claimer that died after claiming the label set but before making the slot
%% live leaves a pending claim; the next writer completes it.
interrupted_claim_completed_by_next_writer(_Config) ->
  #family{inc = Inc} = instrument_series:ensure_family(k1, counter, <<>>, undefined, undefined),
  Canon = {[k], [<<"v">>]},
  ok = instrument_series:write(k1, Canon, fun() -> Canon end, inc()),
  S = instrument_series:slot_of(k1, Canon),
  %% Undo everything after the canon claim: keys, slot row, live epoch.
  ets:delete(instrument_series, {'$s', Inc, key, Canon}),
  ets:delete(instrument_series, {'$s', Inc, slot, S}),
  #family{chunk0 = {Epochs, _}} = instrument_series:family(k1),
  ok = atomics:compare_exchange(Epochs, S, 1, 2),
  instrument_series:purge_cache(),
  ok = instrument_series:write(k1, Canon, fun() -> Canon end, inc()),
  ?assertEqual(S, instrument_series:slot_of(k1, Canon)),
  [#{data := [{[k], [<<"v">>], _}]}] = [E || #{name := k1} = E <- instrument_series:collect_all()],
  ok.

%% The family arbiter row is gone (teardown in progress) while the meta is
%% still published: the claim is undone and the write reports not_found.
loser_after_winner_undo_returns_not_found(_Config) ->
  _ = instrument_series:ensure_family(w8, counter, <<>>, undefined, undefined),
  ets:delete(instrument_series, {w8, family}),
  Canon = {[z], [<<"1">>]},
  ?assertEqual({error, not_found},
               instrument_series:write(w8, Canon, fun() -> Canon end, inc())).

%% ============================================================================
%% Collection
%% ============================================================================

collect_families(_Config) ->
  _ = instrument_series:ensure_family(c1, counter, <<"c1 help">>, undefined, undefined),
  Canon = {[m], [<<"GET">>]},
  ok = instrument_series:write(c1, Canon, fun() -> Canon end, inc(3)),
  [Entry] = [E || #{name := c1} = E <- instrument_series:collect_all()],
  #{type := counter, help := <<"c1 help">>, labels := [m],
    data := [{[m], [<<"GET">>], 3.0}], start_time := T} = Entry,
  ?assert(is_integer(T)),
  ok.

collect_skips_removed_and_empty(_Config) ->
  _ = instrument_series:ensure_family(c2, gauge, <<>>, undefined, undefined),
  ?assertEqual([], [E || #{name := c2} = E <- instrument_series:collect_all()]),
  _ = instrument_series:ensure_family(c3, counter, <<>>, undefined, undefined),
  CanonA = {[k], [<<"a">>]}, CanonB = {[k], [<<"b">>]},
  ok = instrument_series:write(c3, CanonA, fun() -> CanonA end, inc()),
  ok = instrument_series:write(c3, CanonB, fun() -> CanonB end, inc()),
  ok = instrument_registry:remove_label(c3, CanonA),
  [#{data := Data}] = [E || #{name := c3} = E <- instrument_series:collect_all()],
  ?assertEqual([{[k], [<<"b">>], 1.0}], Data),
  ok.

collect_union_and_declared(_Config) ->
  _ = instrument_series:ensure_family(c4, counter, <<>>, undefined, undefined),
  C1 = {[method], [<<"GET">>]}, C2 = {[region], [<<"eu">>]},
  [ok = instrument_series:write(c4, C, fun() -> C end, inc()) || C <- [C1, C2]],
  [#{labels := Union}] = [E || #{name := c4} = E <- instrument_series:collect_all()],
  ?assertEqual([method, region], Union),
  _ = instrument_series:ensure_family(c5, counter, <<>>, [b, a], undefined),
  C3 = {[a, b], [<<"1">>, <<"2">>]},
  ok = instrument_series:write(c5, [<<"2">>, <<"1">>], fun() -> C3 end, inc()),
  [#{labels := [a, b]}] = [E || #{name := c5} = E <- instrument_series:collect_all()],
  ok.

teardown_returns_pt_to_baseline(_Config) ->
  PtBefore  = instrument_pt_key_count(),
  ResBefore = exemplar_row_count(),
  Name = td_hist,
  ok = instrument_metric:new_histogram_vec(Name, <<"teardown hist">>, [path]),
  [ok = instrument_metric:observe_histogram_vec(Name, [P], 0.5)
   || P <- [<<"/a">>, <<"/b">>, <<"/c">>]],
  ?assert(instrument_pt_key_count() > PtBefore),
  ?assertEqual(ResBefore + 3, exemplar_row_count()),
  ok = instrument_registry:unregister(Name),
  ?assertEqual(PtBefore, instrument_pt_key_count()),
  ?assertEqual(ResBefore, exemplar_row_count()),
  ?assertEqual(undefined, instrument_series:family(Name)),
  ok.

%% ============================================================================
%% Chunked slots
%% ============================================================================

%% persistent_term keys grow with chunks, not with series.
pt_keys_bounded_by_chunks(_Config) ->
  os:putenv("OTEL_METRIC_CARDINALITY_LIMIT", "5000"),
  Before = instrument_pt_key_count(),
  _ = instrument_series:ensure_family(pk, counter, <<>>, undefined, undefined),
  write_series(pk, 1, 100),
  %% family meta + idx + chunks 1..3 (+1 prepared ahead)
  ?assert(instrument_pt_key_count() - Before =< 2 + 4),
  write_series(pk, 101, 1999),
  ?assertEqual(1999, instrument_registry:label_count(pk)),
  %% 2000 slots fit in chunks 0..6
  ?assert(instrument_pt_key_count() - Before =< 2 + 7),
  ok.

write_series(Name, From, To) ->
  [ok = instrument_series:write(Name, {[i], [integer_to_binary(I)]},
                                fun() -> {[i], [integer_to_binary(I)]} end, inc())
   || I <- lists:seq(From, To)].

%% Every persistent_term put on the creation path is a fresh key.
no_pt_replace_on_creation(_Config) ->
  os:putenv("OTEL_METRIC_CARDINALITY_LIMIT", "100000"),
  _ = instrument_series:ensure_family(np, counter, <<>>, undefined, undefined),
  Existing = maps:from_list([{K, true} || {K, _} <- persistent_term:get()]),
  Parent = self(),
  Pids = [spawn_link(fun() ->
            write_series(np, W * 1000, W * 1000 + 99),
            Parent ! {done, self()}
          end) || W <- lists:seq(1, 20)],
  [receive {done, P} -> ok end || P <- Pids],
  ?assertEqual(2000, instrument_registry:label_count(np)),
  New = [K || {K, _} <- persistent_term:get(), not maps:is_key(K, Existing)],
  %% only chunk keys were added, each once
  ?assert(lists:all(fun({instrument_chunk, np, _, _}) -> true; (_) -> false end, New)),
  ?assertEqual(length(New), length(lists:usort(New))),
  ok.

%% A process holding a cached entry for a removed label set cannot write into
%% the slot once it holds another label set.
stale_cached_writer_cannot_write_reused_slot(_Config) ->
  application:set_env(instrument, series_reuse_quarantine_ms, 0),
  _ = instrument_series:ensure_family(ru, counter, <<>>, undefined, undefined),
  A = {[k], [<<"a">>]}, B = {[k], [<<"b">>]},
  ok = instrument_series:write(ru, A, fun() -> A end, inc()),
  SlotA = instrument_series:slot_of(ru, A),
  ok = instrument_registry:remove_label(ru, A),
  %% B takes A's slot
  ok = instrument_series:write(ru, B, fun() -> B end, inc(10)),
  ?assertEqual(SlotA, instrument_series:slot_of(ru, B)),
  %% the stale entry for A misses and A becomes a new series elsewhere
  ok = instrument_series:write(ru, A, fun() -> A end, inc()),
  ?assertEqual(10.0, value(ru, B)),
  ?assertEqual(1.0, value(ru, A)),
  ?assertNotEqual(SlotA, instrument_series:slot_of(ru, A)),
  ok.

quarantine_keeps_removed_slot_unused(_Config) ->
  application:set_env(instrument, series_reuse_quarantine_ms, 60000),
  _ = instrument_series:ensure_family(qu, counter, <<>>, undefined, undefined),
  A = {[k], [<<"a">>]}, B = {[k], [<<"b">>]},
  ok = instrument_series:write(qu, A, fun() -> A end, inc()),
  SlotA = instrument_series:slot_of(qu, A),
  ok = instrument_registry:remove_label(qu, A),
  ok = instrument_series:write(qu, B, fun() -> B end, inc()),
  ?assertEqual(SlotA + 1, instrument_series:slot_of(qu, B)),
  ok.

%% A handle obtained with labels/2 writes straight into its cell, so its slot
%% is never given to another label set.
pinned_handle_slot_never_reused(_Config) ->
  application:set_env(instrument, series_reuse_quarantine_ms, 0),
  ok = instrument_metric:new_counter_vec(pv, <<"h">>, [k]),
  H = instrument_metric:labels(pv, [a]),
  SlotA = instrument_series:slot_of(pv, [a]),
  ok = instrument_metric:remove_label(pv, [a]),
  ok = instrument_metric:inc_counter_vec(pv, [b]),
  ?assertNotEqual(SlotA, instrument_series:slot_of(pv, [b])),
  ok = instrument_counter:inc_counter(H),
  ?assertEqual(1.0, instrument_metric:get_counter_vec(pv, [b])),
  ok.

%% A chunk claimed in ETS by a process that died before publishing it is
%% still usable and gets published by the next reader.
dead_chunk_publisher_is_repaired(_Config) ->
  #family{inc = Inc} = Fam = instrument_series:ensure_family(dp, counter, <<>>, undefined, undefined),
  Dead = spawn(fun() -> ok end),
  Ref = monitor(process, Dead),
  receive {'DOWN', Ref, process, Dead, _} -> ok end,
  Chunk = {atomics:new(32, []), list_to_tuple([begin {ok, G} = instrument_nif:new_gauge(),
                                                     #metric{name = series, handle = {G, 0}} end
                                               || _ <- lists:seq(1, 32)])},
  true = ets:insert_new(instrument_series, {{'$s', Inc, chunk, 1}, Chunk, Dead}),
  ?assertEqual(Chunk, instrument_series:ensure_chunk(dp, Fam, 1)),
  ?assertEqual(Chunk, persistent_term:get({instrument_chunk, dp, Inc, 1})),
  write_series(dp, 1, 30),
  ?assertEqual(30, instrument_registry:label_count(dp)),
  ok.

%% A re-created family is a new incarnation: no stale key collides with it and
%% a stale cached entry goes to the new series.
recreate_after_unregister_no_collision(_Config) ->
  _ = instrument_series:ensure_family(rc, counter, <<>>, undefined, undefined),
  A = {[k], [<<"a">>]},
  write_series(rc, 1, 40),
  ok = instrument_series:write(rc, A, fun() -> A end, inc(5)),
  #family{inc = OldInc} = instrument_series:family(rc),
  ok = instrument_registry:unregister(rc),
  ?assertEqual([], [K || {{instrument_chunk, rc, _, _} = K, _} <- persistent_term:get()]),
  #family{inc = NewInc} = instrument_series:ensure_family(rc, counter, <<>>, undefined, undefined),
  ?assertNotEqual(OldInc, NewInc),
  ok = instrument_series:write(rc, A, fun() -> A end, inc()),
  ?assertEqual(1.0, value(rc, A)),
  ok.

app_restart_invalidates_cached_entries(_Config) ->
  _ = instrument_series:ensure_family(ar, counter, <<>>, undefined, undefined),
  A = {[k], [<<"a">>]},
  ok = instrument_series:write(ar, A, fun() -> A end, inc(5)),
  application:stop(instrument),
  {ok, _} = application:ensure_all_started(instrument),
  _ = instrument_series:ensure_family(ar, counter, <<>>, undefined, undefined),
  ok = instrument_series:write(ar, A, fun() -> A end, inc()),
  ?assertEqual(1.0, value(ar, A)),
  ok.

%% Entries for removed series are swept from the process dictionary.
cache_sweep_bounds_entries(_Config) ->
  application:set_env(instrument, series_reuse_quarantine_ms, 0),
  _ = instrument_series:ensure_family(cs, counter, <<>>, undefined, undefined),
  put('$instrument_series_limit', 100),
  lists:foreach(fun(Round) ->
    Keys = [{[k], [integer_to_binary(Round * 1000 + I)]} || I <- lists:seq(1, 60)],
    [ok = instrument_series:write(cs, K, fun() -> K end, inc()) || K <- Keys],
    ok = instrument_registry:clear_labels(cs)
  end, lists:seq(1, 10)),
  Cached = [K || {{'$instrument_series', cs, _} = K, _} <- get()],
  ?assert(length(Cached) =< 200),
  ok.

%% Pre-created histogram cells get an exemplar reservoir only when used.
reservoirs_only_for_live_series(_Config) ->
  Before = exemplar_row_count(),
  _ = instrument_series:ensure_family(rh, histogram, <<>>, undefined, [1, 2]),
  ?assertEqual(Before, exemplar_row_count()),
  A = {[k], [<<"a">>]},
  ok = instrument_series:write(rh, A, fun() -> A end,
                               fun(R) -> instrument_histogram:observe_histogram(R, 1) end),
  ?assertEqual(Before + 1, exemplar_row_count()),
  ok = instrument_registry:remove_label(rh, A),
  ?assertEqual(Before, exemplar_row_count()),
  ok.

%% Slots map to growing chunks: 16, 32, ... 1024, then 1024 per chunk.
slot_arithmetic(_Config) ->
  _ = instrument_series:ensure_family(sa, counter, <<>>, undefined, undefined),
  os:putenv("OTEL_METRIC_CARDINALITY_LIMIT", "5000"),
  write_series(sa, 1, 3000),
  ?assertEqual(3001, instrument_series:high_water(sa)),
  #family{inc = Inc} = instrument_series:family(sa),
  %% chunk 8 may also exist: it is prepared ahead asynchronously
  Chunks = lists:sort([C || {{instrument_chunk, sa, I, C}, _} <- persistent_term:get(),
                            I =:= Inc, C =< 7]),
  ?assertEqual(lists:seq(1, 7), Chunks),
  Sizes = [tuple_size(element(2, persistent_term:get({instrument_chunk, sa, Inc, C}))) || C <- Chunks],
  ?assertEqual([32, 64, 128, 256, 512, 1024, 1024], Sizes),
  ok.

%% ============================================================================

instrument_pt_key_count() ->
  length([K || {K, _} <- persistent_term:get(),
               instrument_registry:is_instrument_key(K)]).

exemplar_row_count() ->
  case ets:info(instrument_exemplar_reservoirs, size) of
    undefined -> 0;
    N -> N
  end.
