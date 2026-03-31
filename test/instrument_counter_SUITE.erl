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
  counter_with_name/1,
  high_concurrency/1,
  read_during_write/1
]).


all() ->
  [
    starts_with_zero,
    increment_correctly,
    is_concurrent,
    counter_with_name,
    high_concurrency,
    read_during_write
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

%% ============================================================================
%% Extended Concurrency Tests
%% ============================================================================

high_concurrency(_Config) ->
  %% 100 processes x 100 increments = 10000 total operations
  M = instrument:new_counter(high_conc_test, "high concurrency test"),
  NumProcesses = 100,
  IncrementsPerProcess = 100,
  ExpectedTotal = float(NumProcesses * IncrementsPerProcess),

  In = lists:seq(1, NumProcesses),
  Out = pmap(fun(_) ->
    lists:foreach(fun(_) ->
      ok = instrument:inc_counter(M)
    end, lists:seq(1, IncrementsPerProcess)),
    ok
  end, In),

  %% All processes should succeed
  NumProcesses = length([ok || {ok, ok} <- Out]),

  %% Counter should have exact value
  ExpectedTotal = instrument:get_counter(M).

read_during_write(_Config) ->
  %% Test read consistency while writes are happening
  M = instrument:new_counter(rw_test, "read-write test"),
  NumWriters = 10,
  NumReaders = 5,
  WritesPerWriter = 1000,
  ReadIterations = 100,

  Parent = self(),

  %% Start writer processes
  WriterPids = [spawn_link(fun() ->
    lists:foreach(fun(_) ->
      ok = instrument:inc_counter(M)
    end, lists:seq(1, WritesPerWriter)),
    Parent ! {writer_done, self()}
  end) || _ <- lists:seq(1, NumWriters)],

  %% Start reader processes that verify monotonic reads
  ReaderPids = [spawn_link(fun() ->
    read_monotonic_loop(M, ReadIterations, 0.0),
    Parent ! {reader_done, self()}
  end) || _ <- lists:seq(1, NumReaders)],

  %% Wait for all writers
  lists:foreach(fun(Pid) ->
    receive {writer_done, Pid} -> ok end
  end, WriterPids),

  %% Wait for all readers
  lists:foreach(fun(Pid) ->
    receive {reader_done, Pid} -> ok after 5000 -> ok end
  end, ReaderPids),

  %% Final value should be exact
  ExpectedFinal = float(NumWriters * WritesPerWriter),
  ExpectedFinal = instrument:get_counter(M).

read_monotonic_loop(_M, 0, _LastValue) ->
  ok;
read_monotonic_loop(M, N, LastValue) ->
  CurrentValue = instrument:get_counter(M),
  %% Value should never decrease (monotonic)
  true = CurrentValue >= LastValue,
  timer:sleep(1),
  read_monotonic_loop(M, N - 1, CurrentValue).
