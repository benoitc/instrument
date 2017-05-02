%% Copyright (c) 2017, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_gauge_SUITE).
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
  starts_with_zero/1,
  add_correctly/1,
  substract_correctly/1,
  can_be_reset/1
]).


all() ->
  [
    starts_with_zero,
    add_correctly,
    substract_correctly,
    can_be_reset
  ].


init_per_suite(Config) ->
  Config.

end_per_suite(Config) ->
  Config.


init_per_testcase(_, Config) ->
  Config.

end_per_testcase(_Config) ->
  ok.


%% ==============
%% TESTS
%% ==============

starts_with_zero(_Config) ->
  M = instrument_gauge:new(c, "no help"),
  0.0 = instrument_gauge:get(M).

add_correctly(_Config) ->
  M = instrument_gauge:new(c, "no help"),
  ok = instrument_gauge:inc(M),
  1.0 = instrument_gauge:get(M),
  ok = instrument_gauge:inc(M, 41),
  42.0 = instrument_gauge:get(M).

substract_correctly(_Config) ->
  M = instrument_gauge:new(c, "no help"),
  ok = instrument_gauge:dec(M),
  -1.0 = instrument_gauge:get(M),
  ok = instrument_gauge:dec(M, 41),
  -42.0 = instrument_gauge:get(M).

can_be_reset(_Config) ->
  M = instrument_gauge:new(c, "no help"),
  ok = instrument_gauge:set(M, 1),
  ok = instrument_gauge:set(M, 2),
  2.0 = instrument_gauge:get(M).