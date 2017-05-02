%% Copyright (c) 2017, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_counter_SUITE).
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
  increment_correctly/1,
  is_concurrent/1
]).


all() ->
  [
    starts_with_zero,
    increment_correctly,
    is_concurrent
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
  M = instrument_counter:new(c, "no help"),
  0.0 = instrument_counter:get(M).

increment_correctly(_Config) ->
  M = instrument_counter:new(c, "no help"),
  ok = instrument_counter:inc(M),
  1.0 = instrument_counter:get(M),
  ok = instrument_counter:inc(M, 41),
  42.0 = instrument_counter:get(M).

is_concurrent(_Config) ->
  M = instrument_counter:new(test, ""),
  In = lists:seq(1, 1000),
  Out = pmap(fun(I) -> ok = instrument_counter:inc(M), I end, In),
  In = [I || {ok, I} <- Out],
  1000.0 = instrument_counter:get(M).



pmap(F, Es) ->
  Parent = self(),
  Running = [
    spawn_monitor(fun() -> Parent ! {self(), F(E)} end)
    || E <- Es
  ],
  collect(Running, 5000).

collect([], _Timeout) -> [];
collect([{Pid, MRef} | Next], Timeout) ->
  receive
    {Pid, Res} ->
      erlang:demonitor(MRef, [flush]),
      [{ok, Res} | collect(Next, Timeout)];
    {'DOWN', MRef, process, Pid, Reason} ->
      [{error, Reason} | collect(Next, Timeout)]
  after Timeout ->
    exit(pmap_timeout)
  end.


  