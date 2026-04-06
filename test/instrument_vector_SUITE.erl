%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.
-module(instrument_vector_SUITE).
-author("benoitc").

%% API
-export([
  all/0,
  init_per_suite/1,
  end_per_suite/1,
  init_per_testcase/2,
  end_per_testcase/1
]).



%% TESTS
-export([
  starts_with_no_labels/1,
  maintain_state_for_a_single_label/1,
  maintain_state_for_multiple_labels/1,
  gauge_vec_operations/1,
  histogram_vec_operations/1,
  concurrent_vec_operations/1
]).


all() ->
  [
    starts_with_no_labels,
    maintain_state_for_a_single_label,
    maintain_state_for_multiple_labels,
    gauge_vec_operations,
    histogram_vec_operations,
    concurrent_vec_operations
  ].


init_per_suite(Config) ->
  ok = application:start(instrument),
  Config.

end_per_suite(Config) ->
  ok = application:stop(instrument),
  Config.


init_per_testcase(_, Config) ->
  ok = instrument:unregister_all(),
  Config.

end_per_testcase(_Config) ->
  ok = instrument:unregister_all(),
  timer:sleep(400),
  ok.


starts_with_no_labels(_Config) ->
  M = instrument:new_vector(["a", "b"], counter, "name", "help"),
  [] = instrument:get_vector_with(M, get_counter).

maintain_state_for_a_single_label(_Config) ->
  M = instrument:new_vector([a, b], counter, "name", "help"),
  ok = instrument:with_label(M, ["foo", "bar"], inc_counter),
  [{["foo", "bar"], 1.0}] = instrument:get_vector_with(M, get_counter).


maintain_state_for_multiple_labels(_Config) ->
  M = instrument:new_vector(["a"], counter, "name", "help"),
  ok = instrument:with_label(M, ["foo"], inc_counter),
  ok = instrument:with_label(M, ["bar"], inc_counter),
  [{["foo"], 1.0}, {["bar"], 1.0}] = instrument:get_vector_with(M, get_counter).


%% ==============
%% Vec API Tests
%% ==============

gauge_vec_operations(_Config) ->
  ok = instrument:new_gauge_vec(connections, "Active connections", [server]),
  ok = instrument:set_gauge_vec(connections, [<<"s1">>], 10),
  ok = instrument:set_gauge_vec(connections, [<<"s2">>], 20),
  10.0 = instrument:get_gauge_vec(connections, [<<"s1">>]),
  20.0 = instrument:get_gauge_vec(connections, [<<"s2">>]),
  ok = instrument:inc_gauge_vec(connections, [<<"s1">>], 5),
  15.0 = instrument:get_gauge_vec(connections, [<<"s1">>]),
  ok = instrument:dec_gauge_vec(connections, [<<"s1">>], 3),
  12.0 = instrument:get_gauge_vec(connections, [<<"s1">>]),
  ok = instrument:inc_gauge_vec(connections, [<<"s1">>]),
  13.0 = instrument:get_gauge_vec(connections, [<<"s1">>]),
  ok = instrument:dec_gauge_vec(connections, [<<"s1">>]),
  12.0 = instrument:get_gauge_vec(connections, [<<"s1">>]),
  ok.

histogram_vec_operations(_Config) ->
  ok = instrument:new_histogram_vec(latency, "Request latency", [endpoint], [0.1, 0.5, 1.0]),
  ok = instrument:observe_histogram_vec(latency, [<<"/api">>], 0.05),
  ok = instrument:observe_histogram_vec(latency, [<<"/api">>], 0.3),
  ok = instrument:observe_histogram_vec(latency, [<<"/web">>], 0.8),
  #{count := CountApi} = instrument:get_histogram_vec(latency, [<<"/api">>]),
  #{count := CountWeb} = instrument:get_histogram_vec(latency, [<<"/web">>]),
  true = (CountApi >= 2.0),
  true = (CountWeb >= 1.0),
  ok.

concurrent_vec_operations(_Config) ->
  ok = instrument:new_counter_vec(requests, "Requests", [method]),
  NumProcesses = 50,
  OpsPerProcess = 100,

  Parent = self(),
  Pids = [spawn_link(fun() ->
    lists:foreach(fun(_) ->
      instrument:inc_counter_vec(requests, [<<"GET">>])
    end, lists:seq(1, OpsPerProcess)),
    Parent ! {done, self()}
  end) || _ <- lists:seq(1, NumProcesses)],

  lists:foreach(fun(Pid) ->
    receive {done, Pid} -> ok end
  end, Pids),

  Expected = float(NumProcesses * OpsPerProcess),
  Expected = instrument:get_counter_vec(requests, [<<"GET">>]),
  ok.
