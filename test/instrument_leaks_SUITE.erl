%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.
-module(instrument_leaks_SUITE).
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
  histogram_unregister_frees_exemplar_reservoir/1,
  histogram_vec_unregister_frees_all_reservoirs/1,
  unregister_all_frees_all_reservoirs/1,
  baggage_set_does_not_leak_process_dict/1
]).

all() ->
  [
    histogram_unregister_frees_exemplar_reservoir,
    histogram_vec_unregister_frees_all_reservoirs,
    unregister_all_frees_all_reservoirs,
    baggage_set_does_not_leak_process_dict
  ].

init_per_suite(Config) ->
  _ = application:load(instrument),
  ok = application:set_env(instrument, auto_register_exporters, false),
  _ = application:ensure_all_started(instrument),
  Config.

end_per_suite(_Config) ->
  ok = application:stop(instrument),
  ok.

init_per_testcase(_TC, Config) ->
  ok = instrument_metric:unregister_all(),
  Config.

end_per_testcase(_TC, _Config) ->
  ok = instrument_metric:unregister_all(),
  ok.

%% Creating and destroying a simple histogram must not leave orphaned rows
%% in the exemplar reservoir table.
histogram_unregister_frees_exemplar_reservoir(_Config) ->
  Baseline = reservoir_table_size(),
  _ = instrument_metric:new_histogram(leak_latency, "Latency"),
  instrument_metric:observe_histogram(leak_latency, 0.05),
  ?assertEqual(Baseline + 1, reservoir_table_size()),
  ok = instrument_metric:unregister(leak_latency),
  ?assertEqual(Baseline, reservoir_table_size()),
  ok.

%% Creating a histogram vector with N label combinations must free N
%% reservoirs on unregister.
histogram_vec_unregister_frees_all_reservoirs(_Config) ->
  Baseline = reservoir_table_size(),
  ok = instrument_metric:new_histogram_vec(leak_latency_vec, "Latency", [path]),
  N = 50,
  lists:foreach(fun(I) ->
    ok = instrument_metric:observe_histogram_vec(
      leak_latency_vec, [integer_to_binary(I)], 0.1)
  end, lists:seq(1, N)),
  ?assertEqual(Baseline + N, reservoir_table_size()),
  ok = instrument_metric:unregister(leak_latency_vec),
  ?assertEqual(Baseline, reservoir_table_size()),
  ok.

%% unregister_all must wipe every reservoir.
unregister_all_frees_all_reservoirs(_Config) ->
  _ = instrument_metric:new_histogram(leak_h1, "H1"),
  _ = instrument_metric:new_histogram(leak_h2, "H2"),
  ok = instrument_metric:new_histogram_vec(leak_h3, "H3", [user]),
  ok = instrument_metric:observe_histogram_vec(leak_h3, [<<"alice">>], 0.1),
  ok = instrument_metric:observe_histogram_vec(leak_h3, [<<"bob">>], 0.2),
  true = reservoir_table_size() > 0,
  ok = instrument_metric:unregister_all(),
  ?assertEqual(0, reservoir_table_size()),
  ok.

%% Calling baggage:set/remove/clear repeatedly on a single process must not
%% leak {'$instrument_context', Token} entries in the process dictionary.
baggage_set_does_not_leak_process_dict(_Config) ->
  Before = count_context_tokens(),
  lists:foreach(fun(I) ->
    instrument_baggage:set(<<"k">>, integer_to_binary(I))
  end, lists:seq(1, 500)),
  ok = instrument_baggage:remove(<<"k">>),
  ok = instrument_baggage:clear(),
  After = count_context_tokens(),
  ?assertEqual(Before, After),
  ok.

reservoir_table_size() ->
  case ets:whereis(instrument_exemplar_reservoirs) of
    undefined -> 0;
    _ -> ets:info(instrument_exemplar_reservoirs, size)
  end.

count_context_tokens() ->
  length([K || {K, _} <- erlang:get(),
               is_tuple(K),
               tuple_size(K) =:= 2,
               element(1, K) =:= '$instrument_context']).
