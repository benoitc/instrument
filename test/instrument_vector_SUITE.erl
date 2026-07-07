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

-include_lib("stdlib/include/assert.hrl").



%% TESTS
-export([
  starts_with_no_labels/1,
  maintain_state_for_a_single_label/1,
  maintain_state_for_multiple_labels/1,
  gauge_vec_operations/1,
  histogram_vec_operations/1,
  concurrent_vec_operations/1,
  remove_label_test/1,
  clear_labels_test/1,
  with_label_value_on_first_write/1,
  map_label_resolves_in_declared_order/1
]).


all() ->
  [
    starts_with_no_labels,
    maintain_state_for_a_single_label,
    maintain_state_for_multiple_labels,
    gauge_vec_operations,
    histogram_vec_operations,
    concurrent_vec_operations,
    remove_label_test,
    clear_labels_test,
    with_label_value_on_first_write,
    map_label_resolves_in_declared_order
  ].


init_per_suite(Config) ->
  ok = application:start(instrument),
  Config.

end_per_suite(Config) ->
  ok = application:stop(instrument),
  Config.


init_per_testcase(_, Config) ->
  ok = instrument_metric:unregister_all(),
  Config.

end_per_testcase(_Config) ->
  ok = instrument_metric:unregister_all(),
  timer:sleep(400),
  ok.


starts_with_no_labels(_Config) ->
  M = instrument_metric:new_vector(["a", "b"], counter, "name", "help"),
  [] = instrument_metric:get_vector_with(M, get_counter).

maintain_state_for_a_single_label(_Config) ->
  M = instrument_metric:new_vector([a, b], counter, "name", "help"),
  ok = instrument_metric:with_label(M, ["foo", "bar"], inc_counter),
  [{["foo", "bar"], 1.0}] = instrument_metric:get_vector_with(M, get_counter).


maintain_state_for_multiple_labels(_Config) ->
  M = instrument_metric:new_vector(["a"], counter, "name", "help"),
  ok = instrument_metric:with_label(M, ["foo"], inc_counter),
  ok = instrument_metric:with_label(M, ["bar"], inc_counter),
  [{["foo"], 1.0}, {["bar"], 1.0}] = instrument_metric:get_vector_with(M, get_counter).


%% ==============
%% Vec API Tests
%% ==============

gauge_vec_operations(_Config) ->
  ok = instrument_metric:new_gauge_vec(connections, "Active connections", [server]),
  ok = instrument_metric:set_gauge_vec(connections, [<<"s1">>], 10),
  ok = instrument_metric:set_gauge_vec(connections, [<<"s2">>], 20),
  10.0 = instrument_metric:get_gauge_vec(connections, [<<"s1">>]),
  20.0 = instrument_metric:get_gauge_vec(connections, [<<"s2">>]),
  ok = instrument_metric:inc_gauge_vec(connections, [<<"s1">>], 5),
  15.0 = instrument_metric:get_gauge_vec(connections, [<<"s1">>]),
  ok = instrument_metric:dec_gauge_vec(connections, [<<"s1">>], 3),
  12.0 = instrument_metric:get_gauge_vec(connections, [<<"s1">>]),
  ok = instrument_metric:inc_gauge_vec(connections, [<<"s1">>]),
  13.0 = instrument_metric:get_gauge_vec(connections, [<<"s1">>]),
  ok = instrument_metric:dec_gauge_vec(connections, [<<"s1">>]),
  12.0 = instrument_metric:get_gauge_vec(connections, [<<"s1">>]),
  ok.

histogram_vec_operations(_Config) ->
  ok = instrument_metric:new_histogram_vec(latency, "Request latency", [endpoint], [0.1, 0.5, 1.0]),
  ok = instrument_metric:observe_histogram_vec(latency, [<<"/api">>], 0.05),
  ok = instrument_metric:observe_histogram_vec(latency, [<<"/api">>], 0.3),
  ok = instrument_metric:observe_histogram_vec(latency, [<<"/web">>], 0.8),
  #{count := CountApi} = instrument_metric:get_histogram_vec(latency, [<<"/api">>]),
  #{count := CountWeb} = instrument_metric:get_histogram_vec(latency, [<<"/web">>]),
  true = (CountApi >= 2.0),
  true = (CountWeb >= 1.0),
  ok.

concurrent_vec_operations(_Config) ->
  ok = instrument_metric:new_counter_vec(requests, "Requests", [method]),
  NumProcesses = 50,
  OpsPerProcess = 100,

  Parent = self(),
  Pids = [spawn_link(fun() ->
    lists:foreach(fun(_) ->
      instrument_metric:inc_counter_vec(requests, [<<"GET">>])
    end, lists:seq(1, OpsPerProcess)),
    Parent ! {done, self()}
  end) || _ <- lists:seq(1, NumProcesses)],

  lists:foreach(fun(Pid) ->
    receive {done, Pid} -> ok end
  end, Pids),

  Expected = float(NumProcesses * OpsPerProcess),
  Expected = instrument_metric:get_counter_vec(requests, [<<"GET">>]),
  ok.

remove_label_test(_Config) ->
  ok = instrument_metric:new_counter_vec(rl_requests, "Requests", [method]),
  ok = instrument_metric:inc_counter_vec(rl_requests, [<<"GET">>]),
  ok = instrument_metric:inc_counter_vec(rl_requests, [<<"POST">>]),
  ok = instrument_metric:inc_counter_vec(rl_requests, [<<"POST">>]),
  1.0 = instrument_metric:get_counter_vec(rl_requests, [<<"GET">>]),
  2.0 = instrument_metric:get_counter_vec(rl_requests, [<<"POST">>]),
  %% Drop the GET label
  ok = instrument_metric:remove_label(rl_requests, [<<"GET">>]),
  %% POST is still there
  2.0 = instrument_metric:get_counter_vec(rl_requests, [<<"POST">>]),
  %% GET reads as a fresh counter (recreated on demand at 0.0)
  Got = instrument_metric:get_counter_vec(rl_requests, [<<"GET">>]),
  ?assert(Got == 0.0 orelse Got == undefined),
  ok.

clear_labels_test(_Config) ->
  ok = instrument_metric:new_counter_vec(cl_requests, "Requests", [method]),
  ok = instrument_metric:inc_counter_vec(cl_requests, [<<"GET">>]),
  ok = instrument_metric:inc_counter_vec(cl_requests, [<<"POST">>]),
  1.0 = instrument_metric:get_counter_vec(cl_requests, [<<"GET">>]),
  1.0 = instrument_metric:get_counter_vec(cl_requests, [<<"POST">>]),
  ok = instrument_metric:clear_labels(cl_requests),
  Get = instrument_metric:get_counter_vec(cl_requests, [<<"GET">>]),
  Post = instrument_metric:get_counter_vec(cl_requests, [<<"POST">>]),
  ?assert(Get == 0.0 orelse Get == undefined),
  ?assert(Post == 0.0 orelse Post == undefined),
  ok.

%% Regression: the first write of a brand-new label set through with_label/4
%% must record the passed value, not the no-arg default. The first-touch branch
%% used to recurse into with_label/3 and drop the value argument.
with_label_value_on_first_write(_Config) ->
  M = instrument_metric:new_vector([a, b], counter, "wl4_counter", "help"),
  ok = instrument_metric:with_label(M, ["foo", "bar"], inc_counter, 5),
  [{["foo", "bar"], 5.0}] = instrument_metric:get_vector_with(M, get_counter),
  %% A later write to the same label set adds normally.
  ok = instrument_metric:with_label(M, ["foo", "bar"], inc_counter, 2),
  [{["foo", "bar"], 7.0}] = instrument_metric:get_vector_with(M, get_counter),
  ok.

%% Regression: a map label must resolve values in declared label order, not in
%% the map's key-iteration order. Declared order [method, status] differs from
%% the map's key order here, so a map must address the declared-order row. Both
%% orderings are pre-created as distinct rows so this exercises only resolution.
map_label_resolves_in_declared_order(_Config) ->
  M = instrument_metric:new_vector([method, status], counter, "map_order", "help"),
  ok = instrument_metric:with_label(M, [<<"GET">>, <<"200">>], inc_counter),
  ok = instrument_metric:with_label(M, [<<"200">>, <<"GET">>], inc_counter),
  %% Map must hit the declared-order row [method=GET, status=200], not the
  %% reversed one built from the map's key order.
  ok = instrument_metric:with_label(M, #{method => <<"GET">>, status => <<"200">>}, inc_counter),
  Rows = instrument_metric:get_vector_with(M, get_counter),
  ?assertEqual(2.0, proplists:get_value([<<"GET">>, <<"200">>], Rows)),
  ?assertEqual(1.0, proplists:get_value([<<"200">>, <<"GET">>], Rows)),
  ok.
