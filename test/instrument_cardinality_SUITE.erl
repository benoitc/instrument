%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.
-module(instrument_cardinality_SUITE).
-author("benoitc").

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
  all/0,
  init_per_suite/1,
  end_per_suite/1,
  init_per_testcase/2,
  end_per_testcase/2
]).

-export([
  limit_enforced_with_overflow_bucket/1,
  overflow_shared_across_labels/1,
  under_limit_no_overflow/1,
  counter_reset_on_unregister/1,
  unregister_cleans_persistent_term/1
]).

all() ->
  [
    limit_enforced_with_overflow_bucket,
    overflow_shared_across_labels,
    under_limit_no_overflow,
    counter_reset_on_unregister,
    unregister_cleans_persistent_term
  ].

init_per_suite(Config) ->
  _ = application:load(instrument),
  ok = application:set_env(instrument, auto_register_exporters, false),
  _ = application:ensure_all_started(instrument),
  Config.

end_per_suite(_Config) ->
  ok = application:stop(instrument),
  ok.

init_per_testcase(TC, Config) ->
  ok = instrument_metric:unregister_all(),
  os:putenv("OTEL_METRIC_CARDINALITY_LIMIT", cardinality_limit_for(TC)),
  Config.

end_per_testcase(_TC, _Config) ->
  ok = instrument_metric:unregister_all(),
  os:unsetenv("OTEL_METRIC_CARDINALITY_LIMIT"),
  ok.

cardinality_limit_for(limit_enforced_with_overflow_bucket) -> "10";
cardinality_limit_for(overflow_shared_across_labels) -> "5";
cardinality_limit_for(under_limit_no_overflow) -> "100";
cardinality_limit_for(counter_reset_on_unregister) -> "10";
cardinality_limit_for(unregister_cleans_persistent_term) -> "50";
cardinality_limit_for(_) -> "2000".

%% Creating 20 distinct labels with limit=10 must result in 10 cached series
%% plus one overflow bucket, and the dropped counter must report 10.
limit_enforced_with_overflow_bucket(_Config) ->
  ok = instrument_metric:new_counter_vec(card_req, "Requests", [user]),
  Total = 20,
  Limit = 10,
  lists:foreach(fun(I) ->
    Label = [integer_to_binary(I)],
    ok = instrument_metric:inc_counter_vec(card_req, Label)
  end, lists:seq(1, Total)),

  ?assertEqual(Limit, instrument_registry:label_count(card_req)),
  Dropped = Total - Limit,
  ?assertEqual(Dropped, instrument_registry:cardinality_dropped(card_req)),
  OverflowMetric = instrument_registry:overflow_sentinel(card_req),
  ?assertNotEqual(undefined, OverflowMetric),
  ok.

%% All overflowing labels must share the same overflow metric (one counter,
%% not N counters), so the value must equal the number of dropped increments.
overflow_shared_across_labels(_Config) ->
  ok = instrument_metric:new_counter_vec(card_shared, "Shared", [user]),
  %% First 5 distinct labels fill the cache
  lists:foreach(fun(I) ->
    ok = instrument_metric:inc_counter_vec(card_shared, [integer_to_binary(I)])
  end, lists:seq(1, 5)),
  %% Next 7 increments all go to the overflow bucket
  Overflowed = 7,
  lists:foreach(fun(I) ->
    ok = instrument_metric:inc_counter_vec(card_shared, [integer_to_binary(100 + I)])
  end, lists:seq(1, Overflowed)),

  ?assertEqual(Overflowed, instrument_registry:cardinality_dropped(card_shared)),
  OverflowMetric = instrument_registry:overflow_sentinel(card_shared),
  OverflowValue = instrument_counter:get_counter(OverflowMetric),
  ?assertEqual(float(Overflowed), OverflowValue),
  ok.

%% When total labels stays below the limit, no overflow bucket is created.
under_limit_no_overflow(_Config) ->
  ok = instrument_metric:new_counter_vec(card_under, "Under", [user]),
  lists:foreach(fun(I) ->
    ok = instrument_metric:inc_counter_vec(card_under, [integer_to_binary(I)])
  end, lists:seq(1, 10)),

  ?assertEqual(10, instrument_registry:label_count(card_under)),
  ?assertEqual(0, instrument_registry:cardinality_dropped(card_under)),
  ?assertEqual(undefined, instrument_registry:overflow_sentinel(card_under)),
  ok.

%% Unregistering a metric must reset cardinality accounting.
counter_reset_on_unregister(_Config) ->
  ok = instrument_metric:new_counter_vec(card_reset, "Reset", [user]),
  lists:foreach(fun(I) ->
    ok = instrument_metric:inc_counter_vec(card_reset, [integer_to_binary(I)])
  end, lists:seq(1, 20)),
  true = instrument_registry:label_count(card_reset) > 0,
  true = instrument_registry:cardinality_dropped(card_reset) > 0,

  ok = instrument_metric:unregister(card_reset),
  ?assertEqual(0, instrument_registry:label_count(card_reset)),
  ?assertEqual(0, instrument_registry:cardinality_dropped(card_reset)),
  ?assertEqual(undefined, instrument_registry:overflow_sentinel(card_reset)),
  ok.

%% After unregister, both the label cache entries and the overflow sentinel
%% must be removed from persistent_term.
unregister_cleans_persistent_term(_Config) ->
  ok = instrument_metric:new_counter_vec(card_clean, "Clean", [user]),
  lists:foreach(fun(I) ->
    ok = instrument_metric:inc_counter_vec(card_clean, [integer_to_binary(I)])
  end, lists:seq(1, 100)),
  true = instrument_registry:label_count(card_clean) > 0,

  ok = instrument_metric:unregister(card_clean),
  Keys = persistent_term:get(),
  LeakedLabels = [K || {K, _} <- Keys,
                       is_tuple(K),
                       tuple_size(K) >= 2,
                       (element(1, K) =:= instrument_label
                        orelse element(1, K) =:= instrument_label_overflow),
                       element(2, K) =:= card_clean],
  ?assertEqual([], LeakedLabels),
  ok.
