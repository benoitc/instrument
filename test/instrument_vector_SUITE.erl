%% Copyright (c) 2017, Benoit Chesneau <bchesneau@gmail.com>.
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
  Config.

end_per_suite(Config) ->
  Config.


init_per_testcase(_, Config) ->
  Config.

end_per_testcase(_Config) ->
  ok.


starts_with_no_labels(_Config) ->
  M = instrument_vector:new(["a", "b"], counter, "name", "help"),
  [] = instrument_vector:with(M, fun instrument_counter:get/1).

maintain_state_for_a_single_label(_Config) ->
  M = instrument_vector:new([a, b], counter, "name", "help"),
  {ok, M2} = instrument_vector:with_label(M, ["foo", "bar"], fun instrument_counter:inc/1),
  [{["foo", "bar"], 1.0}] = instrument_vector:with(M2, fun instrument_counter:get/1).


maintain_state_for_multiple_labels(_Config) ->
  M = instrument_vector:new(["a"], counter, "name", "help"),
  {ok, M2} = instrument_vector:with_label(M, ["foo"], fun instrument_counter:inc/1),
  {ok, M3} = instrument_vector:with_label(M2, ["bar"], fun instrument_counter:inc/1),
  [{["foo"], 1.0}, {["bar"], 1.0}] = instrument_vector:with(M3, fun instrument_counter:get/1).


