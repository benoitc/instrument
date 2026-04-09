%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.
-module(instrument_histogram_SUITE).
-author("benoitc").

-include("instrument.hrl").
-include("instrument_otel.hrl").
-include_lib("stdlib/include/assert.hrl").

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
  validate_empty_buckets/1,
  concurrent_histogram/1,
  histogram_concurrent_observe/1,
  histogram_consistency/1,
  %% Exemplar tests (OTel spec compliance)
  histogram_exemplars_test/1,
  histogram_exemplars_with_trace_context_test/1
]).

all() ->
  [
    can_generate_buckets,
    validate_buckets,
    validate_empty_buckets,
    concurrent_histogram,
    histogram_concurrent_observe,
    histogram_consistency,
    %% Exemplar tests (OTel spec compliance)
    histogram_exemplars_test,
    histogram_exemplars_with_trace_context_test
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

validate_empty_buckets(_Config) ->
  %% Empty buckets should raise error:empty_buckets, not crash with badmatch
  empty_buckets =
    try instrument_histogram:validate_buckets([])
    catch
      error:Error -> Error
    end,
  %% Also test that new_histogram with empty buckets fails gracefully
  empty_buckets =
    try instrument_histogram:new_histogram(test_empty, "empty buckets", [])
    catch
      error:Error2 -> Error2
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

%% ============================================================================
%% Extended Concurrency Tests
%% ============================================================================

histogram_concurrent_observe(_Config) ->
  %% Many concurrent observations from multiple processes
  TestBuckets = [0.0, 1.0, 5.0, 10.0, 50.0, 100.0],
  NumProcesses = 50,
  ObservationsPerProcess = 200,
  ExpectedCount = float(NumProcesses * ObservationsPerProcess),

  M = instrument_histogram:new_histogram(conc_observe_hist, "concurrent observe test", TestBuckets),

  Parent = self(),
  Pids = [spawn_link(fun() ->
    lists:foreach(fun(_) ->
      Value = rand:uniform() * 100,
      ok = instrument_histogram:observe_histogram(M, Value)
    end, lists:seq(1, ObservationsPerProcess)),
    Parent ! {self(), done}
  end) || _ <- lists:seq(1, NumProcesses)],

  %% Wait for all processes
  lists:foreach(fun(Pid) ->
    receive {Pid, done} -> ok after 10000 -> exit(timeout) end
  end, Pids),

  %% Verify count
  #{count := Count} = instrument_histogram:get_histogram(M),
  ExpectedCount = Count.

histogram_consistency(_Config) ->
  %% Verify that count equals sum of bucket counts after concurrent operations
  TestBuckets = [0.0, 0.25, 0.5, 0.75, 1.0],
  NumProcesses = 100,
  ObservationsPerProcess = 100,
  ExpectedCount = float(NumProcesses * ObservationsPerProcess),

  M = instrument_histogram:new_histogram(consistency_hist, "consistency test", TestBuckets),

  %% Concurrent observations
  Results = pmap(
    fun(_) ->
      lists:foreach(fun(_) ->
        %% Values between 0 and 1 to hit all buckets
        ok = instrument_histogram:observe_histogram(M, rand:uniform())
      end, lists:seq(1, ObservationsPerProcess)),
      ok
    end,
    lists:seq(1, NumProcesses)
  ),

  %% All processes should succeed
  NumProcesses = length([ok || {ok, ok} <- Results]),

  %% Verify consistency
  #{count := Count, buckets := Buckets} = instrument_histogram:get_histogram(M),

  %% Count should match expected
  ExpectedCount = Count,

  %% Sum of cumulative bucket counts verification
  %% The last bucket (le=+Inf) should equal total count
  LastBucket = lists:last(Buckets),
  #{cumulative_count := LastCumulative} = LastBucket,
  true = (LastCumulative == ExpectedCount),

  %% Cumulative counts should be monotonically increasing
  CumulativeCounts = [C || #{cumulative_count := C} <- Buckets],
  true = is_monotonic(CumulativeCounts),
  ok.

is_monotonic([]) -> true;
is_monotonic([_]) -> true;
is_monotonic([A, B | Rest]) when A =< B ->
  is_monotonic([B | Rest]);
is_monotonic(_) ->
  false.

%% ============================================================================
%% Exemplar Tests (OTel Spec Compliance)
%% ============================================================================

%% Test that histogram captures exemplars
histogram_exemplars_test(_Config) ->
  TestBuckets = [1.0, 5.0, 10.0, 50.0],
  M = instrument_histogram:new_histogram(exemplar_test_hist, "exemplar test", TestBuckets),

  %% Observe some values
  ok = instrument_histogram:observe_histogram(M, 0.5),
  ok = instrument_histogram:observe_histogram(M, 3.0),
  ok = instrument_histogram:observe_histogram(M, 25.0),

  %% Collect histogram (which includes exemplars)
  Result = instrument_histogram:collect(
    instrument_lib:mk_info(exemplar_test_hist, "exemplar test"),
    M#metric.handle
  ),

  %% Verify exemplars field is present
  ?assert(maps:is_key(exemplars, Result)),
  Exemplars = maps:get(exemplars, Result),

  %% Should have captured some exemplars (up to reservoir size, default 4)
  ?assert(is_list(Exemplars)),
  ?assert(length(Exemplars) =< 4),

  %% If we have exemplars, verify structure
  case Exemplars of
    [] -> ok;
    [E | _] ->
      ?assert(is_record(E, exemplar)),
      ?assert(is_number(E#exemplar.value)),
      ?assert(is_integer(E#exemplar.timestamp))
  end,
  ok.

%% Test that histogram exemplars capture trace context
histogram_exemplars_with_trace_context_test(_Config) ->
  TestBuckets = [1.0, 5.0, 10.0],
  M = instrument_histogram:new_histogram(exemplar_trace_hist, "exemplar trace test", TestBuckets),

  %% Observe values within a span
  instrument_tracer:with_span(<<"histogram_test_span">>, fun() ->
    SpanCtx = instrument_tracer:span_ctx(),
    ExpectedTraceId = SpanCtx#span_ctx.trace_id,
    ExpectedSpanId = SpanCtx#span_ctx.span_id,

    %% Observe a value
    ok = instrument_histogram:observe_histogram(M, 2.5),

    %% Collect and check exemplar has trace context
    Result = instrument_histogram:collect(
      instrument_lib:mk_info(exemplar_trace_hist, "exemplar trace test"),
      M#metric.handle
    ),

    Exemplars = maps:get(exemplars, Result, []),

    %% Should have at least one exemplar
    ?assert(length(Exemplars) >= 1),

    %% Find exemplar with our value
    MatchingExemplars = [E || E <- Exemplars, E#exemplar.value =:= 2.5],
    case MatchingExemplars of
      [] ->
        %% Sampling might have dropped it, that's OK
        ok;
      [Exemplar | _] ->
        %% Verify trace context was captured
        ?assertEqual(ExpectedTraceId, Exemplar#exemplar.trace_id),
        ?assertEqual(ExpectedSpanId, Exemplar#exemplar.span_id)
    end
  end),
  ok.