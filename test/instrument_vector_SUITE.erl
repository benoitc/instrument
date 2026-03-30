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
  maintain_state_for_multiple_labels/1
]).


all() ->
  [
    starts_with_no_labels,
    maintain_state_for_a_single_label,
    maintain_state_for_multiple_labels
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


