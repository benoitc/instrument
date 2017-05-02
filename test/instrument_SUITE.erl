%%%-------------------------------------------------------------------
%%% @author benoitc
%%% @copyright (C) 2017, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 02. May 2017 13:58
%%%-------------------------------------------------------------------
-module(instrument_SUITE).
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
  shared_counter/1,
  concurrent_shared_worker/1
]).

all() ->
  [
    shared_counter,
    concurrent_shared_worker
  ].


init_per_suite(Config) ->
  {ok, _} = application:ensure_all_started(instrument),
  Config.

end_per_suite(Config) ->
  ok = application:stop(instrument),
  Config.


init_per_testcase(_, Config) ->
  Config.

end_per_testcase(_Config) ->
  ok.

shared_counter(_Suite) ->
  true = instrument:new_shared_counter(c, "help"),
  ok = instrument:with_shared(c, inc_counter),
  1.0 = instrument:with_shared(c, get_counter),
  ok = instrument:with_shared(c, inc_counter, 41),
  42.0 = instrument:with_shared(c, get_counter),
  ok = instrument:unreg(c),
  {error, not_found} = instrument:with_shared(c, inc_counter).


concurrent_shared_worker(_Config) ->
  true = instrument:new_shared_counter(c, "help"),
  In = lists:seq(1, 1000),
  Out = pmap(fun(I) -> ok = instrument:with_shared(c, inc_counter), I end, In),
  In = [I || {ok, I} <- Out],
  1000.0 = instrument:with_shared(c, get_counter).



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


  