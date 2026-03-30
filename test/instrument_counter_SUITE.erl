%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
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
  is_concurrent/1,
  counter_with_name/1
]).


all() ->
  [
    starts_with_zero,
    increment_correctly,
    is_concurrent,
    counter_with_name
  ].


init_per_suite(Config) ->
  ok = application:start(instrument),
  Config.

end_per_suite(Config) ->
  ok = application:stop(instrument),
  Config.


init_per_testcase(_, Config) ->
  _ = instrument:unregister_all(),
  Config.

end_per_testcase(_Config) ->
  
  ok.


%% ==============
%% TESTS
%% ==============

starts_with_zero(_Config) ->
  M = instrument:new_counter(c, "no help"),
  +0.0 = instrument:get_counter(M).

increment_correctly(_Config) ->
  M = instrument:new_counter(c, "no help"),
  ok = instrument:inc_counter(M),
  1.0 = instrument:get_counter(M),
  ok = instrument:inc_counter(M, 41),
  42.0 = instrument:get_counter(M).

is_concurrent(_Config) ->
  M = instrument:new_counter(test, ""),
  In = lists:seq(1, 1000),
  Out = pmap(fun(I) -> ok = instrument:inc_counter(M), I end, In),
  In = [I || {ok, I} <- Out],
  1000.0 = instrument:get_counter(M).

counter_with_name(_Config) ->
  _ = instrument:new_counter(c, "no help"),
  ok = instrument:inc_counter(c),
  1.0 = instrument:get_counter(c),
  ok = instrument:inc_counter(c, 41),
  42.0 = instrument:get_counter(c).



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


  