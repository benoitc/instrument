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
  degraded_series_still_writable/1,
  loser_after_winner_undo_returns_not_found/1
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
   degraded_series_still_writable,
   loser_after_winner_undo_returns_not_found].

init_per_testcase(_TC, Config) ->
  application:stop(instrument),
  {ok, _} = application:ensure_all_started(instrument),
  Config.

end_per_testcase(_TC, _Config) ->
  application:stop(instrument),
  ok.

family_create_and_lookup(_Config) ->
  Meta = instrument_series:ensure_family(fam_a, counter, <<"help a">>, undefined, undefined),
  #family{kind = counter, help = <<"help a">>, idx = Idx, row_seq = Seq} = Meta,
  ?assert(is_integer(Idx) andalso Idx >= 1),
  ?assertEqual(0, atomics:get(Seq, 1)),
  ?assertEqual(Meta, persistent_term:get({instrument_family, fam_a})),
  ?assertEqual(fam_a, persistent_term:get({instrument_family_idx, Idx})),
  ok.

family_duplicate_create_returns_existing(_Config) ->
  M1 = instrument_series:ensure_family(fam_b, counter, <<"h">>, undefined, undefined),
  %% master semantics: duplicate create returns existing, NO kind check
  M2 = instrument_series:ensure_family(fam_b, gauge, <<"other">>, undefined, undefined),
  ?assertEqual(M1, M2),
  ok.

family_arbiter_fallback(_Config) ->
  M = instrument_series:ensure_family(fam_c, gauge, <<"h">>, undefined, undefined),
  %% simulate a creator killed after claim, before publication
  persistent_term:erase({instrument_family, fam_c}),
  ?assertEqual(M, instrument_series:family(fam_c)),   %% falls back to arbiter row
  %% a later create completes the missing publication
  M = instrument_series:ensure_family(fam_c, gauge, <<"h">>, undefined, undefined),
  ?assertEqual(M, persistent_term:get({instrument_family, fam_c})),
  ok.

write_hot_and_first_touch(_Config) ->
  _ = instrument_series:ensure_family(w1, counter, <<>>, undefined, undefined),
  Canon = {[method], [<<"GET">>]},
  WriteFun = fun(Row) -> instrument_counter:inc_counter(Row, 2) end,
  ok = instrument_series:write(w1, Canon, fun() -> Canon end, WriteFun),
  Row = persistent_term:get({instrument_label, w1, Canon}),
  ok = instrument_series:write(w1, Canon, fun() -> Canon end, WriteFun),
  ?assertEqual(4.0, instrument_counter:get_counter(Row)),
  #family{row_seq = Seq} = instrument_series:family(w1),
  ?assertEqual(1, atomics:get(Seq, 1)),
  ?assertEqual({Canon, Canon, Row}, persistent_term:get({instrument_row, w1, 1})),
  ?assertEqual(1, instrument_registry:label_count(w1)),
  ok.

write_canon_normalization(_Config) ->
  %% vec-style: CacheKey is the raw values list; Canon comes from CanonFun
  _ = instrument_series:ensure_family(w2, counter, <<>>, [method, status], undefined),
  CacheKey = [<<"GET">>, <<"200">>],
  Canon = {[method, status], [<<"GET">>, <<"200">>]},
  ok = instrument_series:write(w2, CacheKey, fun() -> Canon end,
                               fun(R) -> instrument_counter:inc_counter(R) end),
  {Canon, CacheKey, _Row} = persistent_term:get({instrument_row, w2, 1}),
  ok.

concurrent_first_touch_single_winner(_Config) ->
  _ = instrument_series:ensure_family(w3, counter, <<>>, undefined, undefined),
  Canon = {[k], [<<"v">>]},
  Self = self(),
  NProcs = 50,
  Pids = [spawn_link(fun() ->
     receive go -> ok end,
     ok = instrument_series:write(w3, Canon, fun() -> Canon end,
                                  fun(R) -> instrument_counter:inc_counter(R) end),
     Self ! done
   end) || _ <- lists:seq(1, NProcs)],
  [P ! go || P <- Pids],
  [receive done -> ok after 5000 -> ct:fail(timeout) end || _ <- lists:seq(1, NProcs)],
  #family{row_seq = Seq} = instrument_series:family(w3),
  ?assertEqual(1, atomics:get(Seq, 1)),
  Row = persistent_term:get({instrument_label, w3, Canon}),
  ?assertEqual(float(NProcs), instrument_counter:get_counter(Row)),
  ?assertEqual(1, instrument_registry:label_count(w3)),
  ok.

overflow_meter_canon(_Config) ->
  os:putenv("OTEL_METRIC_CARDINALITY_LIMIT", "20"),
  _ = instrument_series:ensure_family(w4, counter, <<>>, undefined, undefined),
  Limit = instrument_config:get_metric_cardinality_limit(),
  [ok = instrument_series:write(w4, {[i], [integer_to_binary(I)]},
         fun() -> {[i], [integer_to_binary(I)]} end,
         fun(R) -> instrument_counter:inc_counter(R) end)
   || I <- lists:seq(1, Limit)],
  ok = instrument_series:write(w4, {[i], [<<"over">>]},
         fun() -> {[i], [<<"over">>]} end,
         fun(R) -> instrument_counter:inc_counter(R) end),
  OvCanon = {[<<"otel.metric.overflow">>], [<<"true">>]},
  OvRow = persistent_term:get({instrument_label, w4, OvCanon}),
  ?assertEqual(1.0, instrument_counter:get_counter(OvRow)),
  ?assert(instrument_registry:cardinality_dropped(w4) >= 1),
  os:unsetenv("OTEL_METRIC_CARDINALITY_LIMIT"),
  ok.

overflow_vec_canon(_Config) ->
  os:putenv("OTEL_METRIC_CARDINALITY_LIMIT", "20"),
  _ = instrument_series:ensure_family(w5, counter, <<>>, [a, b], undefined),
  Limit = instrument_config:get_metric_cardinality_limit(),
  [ok = instrument_series:write(w5, [integer_to_binary(I), <<"x">>],
         fun() -> {[a, b], [integer_to_binary(I), <<"x">>]} end,
         fun(R) -> instrument_counter:inc_counter(R) end)
   || I <- lists:seq(1, Limit)],
  ok = instrument_series:write(w5, [<<"over">>, <<"x">>],
         fun() -> {[a, b], [<<"over">>, <<"x">>]} end,
         fun(R) -> instrument_counter:inc_counter(R) end),
  OvCanon = {[a, b], [<<"otel.metric.overflow">>, <<"otel.metric.overflow">>]},
  ?assertNotEqual(undefined, persistent_term:get({instrument_label, w5, OvCanon}, undefined)),
  os:unsetenv("OTEL_METRIC_CARDINALITY_LIMIT"),
  ok.

unlabeled_negative_updown(_Config) ->
  _ = instrument_series:ensure_family(w6, up_down_counter, <<>>, undefined, undefined),
  Canon = {[], []},
  ok = instrument_series:write(w6, Canon, fun() -> Canon end,
                               fun(R) -> instrument_gauge:inc_gauge(R, 5) end),
  ok = instrument_series:write(w6, Canon, fun() -> Canon end,
                               fun(R) -> instrument_gauge:dec_gauge(R, 2) end),
  Row = persistent_term:get({instrument_label, w6, Canon}),
  ?assertEqual(3.0, instrument_gauge:get_gauge(Row)),
  ok.

degraded_series_still_writable(_Config) ->
  _ = instrument_series:ensure_family(w7, counter, <<>>, undefined, undefined),
  Canon = {[x], [<<"1">>]},
  ok = instrument_series:write(w7, Canon, fun() -> Canon end,
                               fun(R) -> instrument_counter:inc_counter(R) end),
  Row = persistent_term:get({instrument_label, w7, Canon}),
  %% simulate a winner killed between claim and publication
  persistent_term:erase({instrument_label, w7, Canon}),
  ok = instrument_series:write(w7, Canon, fun() -> Canon end,
                               fun(R) -> instrument_counter:inc_counter(R) end),
  ?assertEqual(2.0, instrument_counter:get_counter(Row)),   %% same cell — no misroute
  ok.

%% The winner's post-claim ets:member re-check fails because the family arbiter
%% row is gone (teardown-in-progress). The winner undoes its claim with
%% ets:delete({w8, Canon}) and returns {error, not_found}. Exercises the
%% winner-undo branch end-to-end; also validates the loser path because a
%% concurrent loser whose lookup_element fires after the winner's delete would
%% hit undefined — the 4-arity form prevents a badarg crash there.
loser_after_winner_undo_returns_not_found(_Config) ->
  _ = instrument_series:ensure_family(w8, counter, <<>>, undefined, undefined),
  %% Delete the ETS family arbiter row while leaving the pt entry intact.
  %% first_write/4 finds the family via pt and reaches claim_row; the winner's
  %% post-claim ets:member({w8, family}) → false triggers the undo path.
  ets:delete(instrument_series, {w8, family}),
  Canon = {[z], [<<"1">>]},
  ?assertEqual({error, not_found},
               instrument_series:write(w8, Canon,
                                       fun() -> Canon end,
                                       fun(R) -> instrument_counter:inc_counter(R) end)).
