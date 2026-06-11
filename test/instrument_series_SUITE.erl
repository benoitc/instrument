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
  family_arbiter_fallback/1
]).

all() ->
  [family_create_and_lookup,
   family_duplicate_create_returns_existing,
   family_arbiter_fallback].

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
