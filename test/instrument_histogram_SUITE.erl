%% Copyright (c) 2017, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.
-module(instrument_histogram_SUITE).
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
  can_generate_buckets/1,
  validate_buckets/1,
  concurrent_histogram/1
]).

all() ->
  [
    can_generate_buckets,
    validate_buckets,
    concurrent_histogram
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


can_generate_buckets(_Config) ->
  [-15, -10, -5, 0, 5, 10] = instrument_histogram:linear_buckets(-15, 5, 6),
  [100, 120.0, 144.0] = instrument_histogram:exponential_buckets(100, 1.2, 3).

validate_buckets(_Config) ->
  ok = instrument_histogram:validate_buckets([1, 2]),
  bad_buckets =
    try instrument_histogram:validate_buckets([2, 1])
    catch
      error:Error -> Error
    end,
  ok.

concurrent_histogram(_Config) ->
  TestBuckets = [0.0, 0.5, 1.0, 2.0],
  Mutations = 1000,
  ConcLevel = 5,
  Total = float(Mutations * ConcLevel),
  M = instrument_histogram:new_histogram(test_histogram, "", TestBuckets),
  All = pmap(
    fun(_) ->
      Vars= lists:foldl(
        fun(_, Vars1) ->
          V = quickrand:strong_float(),
          ok = instrument_histogram:observe_histogram(M, V),
          [float(V) | Vars1]
        end,
        [],
        lists:seq(1, Mutations)),
      lists:reverse(Vars)
    end,
    lists:seq(1, ConcLevel)),
  
  AllVars = lists:flatten([Vars || {ok, Vars} <- All]),
  Sum = lists:sum(AllVars),
  Hist = instrument_histogram:get_histogram(M),
  io:format("total = ~p, all sums ~p~nhist: ~p~n", [Total, lists:sum(AllVars), Hist]),
  #{ count := HistTotal, sum := HistSum, buckets := HistBuckets } = Hist,
  HistTotal = Total,
  true = (abs( (HistSum - Sum) / Sum ) < 0.01),
  Counts = get_cumulative_counts(AllVars, TestBuckets),
  HistCounts = [C || #{ cumulative_count := C } <- HistBuckets],
  io:format("counts = ~p, hist counts = ~p~n", [Counts, HistCounts]),
  [] = Counts -- HistCounts.

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

get_cumulative_counts(Vars, Buckets) ->
  Counts = list_to_tuple([0 || _B <- Buckets]),
  Counts2 = lists:foldl(
    fun(Var, Counts1) ->
      fold_buckets_counts(Buckets, Counts1, Var, 1)
    end,
    Counts,
    Vars
  ),
  [float(C) || C <- tuple_to_list(Counts2)].

fold_buckets_counts([Boundary | Rest], Counts1, Value, I) when Boundary > Value ->
  Counts2 = erlang:setelement(I, Counts1, erlang:element(I, Counts1) + 1),
  fold_buckets_counts(Rest, Counts2, Value, I + 1);
fold_buckets_counts([_ | Rest], Counts, Value, I) ->
  fold_buckets_counts(Rest, Counts, Value, I + 1);
fold_buckets_counts([], Counts, _Value, _I) ->
  Counts.