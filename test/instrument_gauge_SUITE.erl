%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
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
  can_be_reset/1,
  gauge_facade_api/1,
  gauge_by_name/1,
  gauge_concurrent/1,
  gauge_high_concurrency/1
]).


all() ->
  [
    starts_with_zero,
    add_correctly,
    substract_correctly,
    can_be_reset,
    gauge_facade_api,
    gauge_by_name,
    gauge_concurrent,
    gauge_high_concurrency
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
  ok.


%% ==============
%% TESTS
%% ==============

starts_with_zero(_Config) ->
  M = instrument_gauge:new_gauge(c, "no help"),
  +0.0 = instrument_gauge:get_gauge(M).

add_correctly(_Config) ->
  M = instrument_gauge:new_gauge(c, "no help"),
  ok = instrument_gauge:inc_gauge(M),
  1.0 = instrument_gauge:get_gauge(M),
  ok = instrument_gauge:inc_gauge(M, 41),
  42.0 = instrument_gauge:get_gauge(M).

substract_correctly(_Config) ->
  M = instrument_gauge:new_gauge(c, "no help"),
  ok = instrument_gauge:dec_gauge(M),
  -1.0 = instrument_gauge:get_gauge(M),
  ok = instrument_gauge:dec_gauge(M, 41),
  -42.0 = instrument_gauge:get_gauge(M).

can_be_reset(_Config) ->
  M = instrument_gauge:new_gauge(c, "no help"),
  ok = instrument_gauge:set_gauge(M, 1),
  ok = instrument_gauge:set_gauge(M, 2),
  2.0 = instrument_gauge:get_gauge(M).

%% ==============
%% Facade API Tests
%% ==============

gauge_facade_api(_Config) ->
  G = instrument:new_gauge(facade_gauge, "Test gauge"),
  +0.0 = instrument:get_gauge(G),
  ok = instrument:set_gauge(G, 10),
  10.0 = instrument:get_gauge(G),
  ok = instrument:inc_gauge(G),
  11.0 = instrument:get_gauge(G),
  ok = instrument:inc_gauge(G, 5),
  16.0 = instrument:get_gauge(G),
  ok = instrument:dec_gauge(G),
  15.0 = instrument:get_gauge(G),
  ok = instrument:dec_gauge(G, 10),
  5.0 = instrument:get_gauge(G),
  ok.

gauge_by_name(_Config) ->
  _ = instrument:new_gauge(named_gauge, "named gauge"),
  ok = instrument:set_gauge(named_gauge, 42),
  42.0 = instrument:get_gauge(named_gauge),
  ok = instrument:inc_gauge(named_gauge, 8),
  50.0 = instrument:get_gauge(named_gauge),
  ok.

%% ==============
%% Concurrency Tests
%% ==============

gauge_concurrent(_Config) ->
  G = instrument:new_gauge(conc_gauge, "concurrent gauge"),
  NumWriters = 10,
  OpsPerWriter = 100,

  Parent = self(),
  Pids = [spawn_link(fun() ->
    lists:foreach(fun(I) ->
      case I rem 2 of
        0 -> instrument:inc_gauge(G);
        1 -> instrument:dec_gauge(G)
      end
    end, lists:seq(1, OpsPerWriter)),
    Parent ! {done, self()}
  end) || _ <- lists:seq(1, NumWriters)],

  lists:foreach(fun(Pid) ->
    receive {done, Pid} -> ok end
  end, Pids),

  %% Each writer does 50 inc + 50 dec = net 0 change
  +0.0 = instrument:get_gauge(G),
  ok.

gauge_high_concurrency(_Config) ->
  G = instrument:new_gauge(high_conc_gauge, "high concurrency gauge"),
  NumProcesses = 100,
  OpsPerProcess = 100,

  Results = pmap(fun(_) ->
    lists:foreach(fun(_) ->
      instrument:inc_gauge(G, 1)
    end, lists:seq(1, OpsPerProcess)),
    ok
  end, lists:seq(1, NumProcesses)),

  NumProcesses = length([ok || {ok, ok} <- Results]),
  Expected = float(NumProcesses * OpsPerProcess),
  Expected = instrument:get_gauge(G),
  ok.

%% ==============
%% Helper Functions
%% ==============

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