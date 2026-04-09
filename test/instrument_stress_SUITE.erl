%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_stress_SUITE).
-author("benoitc").

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("instrument_otel.hrl").

%% API
-export([
  all/0,
  groups/0,
  init_per_suite/1,
  end_per_suite/1,
  init_per_group/2,
  end_per_group/2,
  init_per_testcase/2,
  end_per_testcase/2
]).

%% Counter stress tests
-export([
  counter_concurrent_increments/1,
  counter_vec_high_cardinality/1
]).

%% Gauge stress tests
-export([
  gauge_concurrent_updates/1,
  gauge_vec_concurrent/1
]).

%% Histogram stress tests
-export([
  histogram_concurrent_observations/1,
  histogram_read_during_write/1
]).

%% Span stress tests
-export([
  span_high_throughput/1,
  span_nested_deep/1,
  span_concurrent_modifications/1
]).

%% Registry stress tests
-export([
  registry_concurrent_register/1,
  registry_register_unregister_cycle/1
]).

all() ->
  [{group, stress}].

groups() ->
  [
    {stress, [], [
      counter_concurrent_increments,
      counter_vec_high_cardinality,
      gauge_concurrent_updates,
      gauge_vec_concurrent,
      histogram_concurrent_observations,
      histogram_read_during_write,
      span_high_throughput,
      span_nested_deep,
      span_concurrent_modifications,
      registry_concurrent_register,
      registry_register_unregister_cycle
    ]}
  ].

init_per_suite(Config) ->
  _ = application:ensure_all_started(crypto),
  ok = application:start(instrument),
  Config.

end_per_suite(_Config) ->
  ok = application:stop(instrument),
  ok.

init_per_group(_Group, Config) ->
  Config.

end_per_group(_Group, _Config) ->
  ok.

init_per_testcase(_TestCase, Config) ->
  Config.

end_per_testcase(_TestCase, _Config) ->
  %% Clean up any registered metrics
  catch instrument_metric:unregister_all(),
  %% Clear context
  erlang:erase('$instrument_context'),
  ok.

%% ============================================================================
%% Stress Test Helpers
%% ============================================================================

%% Spawn N processes, each running Fun, collect results
stress_test(N, Fun) ->
  Parent = self(),
  Pids = [spawn_link(fun() -> Parent ! {self(), Fun()} end)
          || _ <- lists:seq(1, N)],
  [receive {Pid, Result} -> Result end || Pid <- Pids].

%% ============================================================================
%% Counter Stress Tests
%% ============================================================================

counter_concurrent_increments(_Config) ->
  %% 100 processes x 10000 increments each = 1,000,000 total
  NumProcesses = 100,
  IncrementsPerProcess = 10000,
  ExpectedTotal = float(NumProcesses * IncrementsPerProcess),

  M = instrument_metric:new_counter(stress_counter, <<"stress test counter">>),

  Results = stress_test(NumProcesses, fun() ->
    lists:foreach(fun(_) ->
      ok = instrument_metric:inc_counter(M)
    end, lists:seq(1, IncrementsPerProcess)),
    ok
  end),

  %% All processes should succeed
  ?assertEqual(NumProcesses, length([ok || ok <- Results])),

  %% Counter value should be exact
  ActualValue = instrument_metric:get_counter(M),
  ?assertEqual(ExpectedTotal, ActualValue),
  ok.

counter_vec_high_cardinality(_Config) ->
  %% Create counter vector with many label combinations
  NumLabels = 100,
  IncrementsPerLabel = 100,

  _Vec = instrument_metric:new_counter_vec(stress_counter_vec, <<"high cardinality test">>, [method, status]),

  %% Concurrent updates to different labels
  Results = stress_test(NumLabels, fun() ->
    Method = list_to_binary(["method_", integer_to_list(rand:uniform(10))]),
    Status = list_to_binary(["status_", integer_to_list(rand:uniform(10))]),
    lists:foreach(fun(_) ->
      ok = instrument_metric:inc_counter_vec(stress_counter_vec, [Method, Status])
    end, lists:seq(1, IncrementsPerLabel)),
    ok
  end),

  ?assertEqual(NumLabels, length([ok || ok <- Results])),
  ok.

%% ============================================================================
%% Gauge Stress Tests
%% ============================================================================

gauge_concurrent_updates(_Config) ->
  %% Rapid concurrent set/inc/dec operations
  NumProcesses = 50,
  OpsPerProcess = 5000,

  M = instrument_metric:new_gauge(stress_gauge, <<"stress test gauge">>),

  Results = stress_test(NumProcesses, fun() ->
    lists:foreach(fun(_) ->
      Op = rand:uniform(3),
      case Op of
        1 -> instrument_metric:inc_gauge(M);
        2 -> instrument_metric:dec_gauge(M);
        3 -> instrument_metric:set_gauge(M, rand:uniform(1000))
      end
    end, lists:seq(1, OpsPerProcess)),
    ok
  end),

  ?assertEqual(NumProcesses, length([ok || ok <- Results])),
  %% Just verify gauge can still be read
  Value = instrument_metric:get_gauge(M),
  ?assert(is_number(Value)),
  ok.

gauge_vec_concurrent(_Config) ->
  %% Vector gauge under concurrent load
  NumProcesses = 50,
  OpsPerProcess = 1000,

  _Vec = instrument_metric:new_gauge_vec(stress_gauge_vec, <<"gauge vec stress">>, [node, service]),

  Results = stress_test(NumProcesses, fun() ->
    Node = list_to_binary(["node_", integer_to_list(rand:uniform(5))]),
    Service = list_to_binary(["service_", integer_to_list(rand:uniform(5))]),
    lists:foreach(fun(_) ->
      Op = rand:uniform(3),
      case Op of
        1 -> instrument_metric:inc_gauge_vec(stress_gauge_vec, [Node, Service]);
        2 -> instrument_metric:dec_gauge_vec(stress_gauge_vec, [Node, Service]);
        3 -> instrument_metric:set_gauge_vec(stress_gauge_vec, [Node, Service], rand:uniform(100))
      end
    end, lists:seq(1, OpsPerProcess)),
    ok
  end),

  ?assertEqual(NumProcesses, length([ok || ok <- Results])),
  ok.

%% ============================================================================
%% Histogram Stress Tests
%% ============================================================================

histogram_concurrent_observations(_Config) ->
  %% Many concurrent observations
  NumProcesses = 100,
  ObservationsPerProcess = 5000,
  ExpectedCount = float(NumProcesses * ObservationsPerProcess),

  Buckets = [0.0, 0.1, 0.5, 1.0, 2.0, 5.0, 10.0],
  M = instrument_metric:new_histogram(stress_histogram, <<"stress histogram">>, Buckets),

  Results = stress_test(NumProcesses, fun() ->
    lists:foreach(fun(_) ->
      ok = instrument_metric:observe_histogram(M, rand:uniform() * 10)
    end, lists:seq(1, ObservationsPerProcess)),
    ok
  end),

  ?assertEqual(NumProcesses, length([ok || ok <- Results])),

  %% Verify count matches
  #{count := Count} = instrument_metric:get_histogram(M),
  ?assertEqual(ExpectedCount, Count),
  ok.

histogram_read_during_write(_Config) ->
  %% Concurrent reads and writes to test consistency
  NumWriters = 50,
  NumReaders = 20,
  ObservationsPerWriter = 2000,

  Buckets = [0.0, 1.0, 5.0, 10.0],
  M = instrument_metric:new_histogram(rw_histogram, <<"read-write histogram">>, Buckets),

  Parent = self(),

  %% Start writers
  WriterPids = [spawn_link(fun() ->
    lists:foreach(fun(_) ->
      ok = instrument_metric:observe_histogram(M, rand:uniform() * 10)
    end, lists:seq(1, ObservationsPerWriter)),
    Parent ! {writer_done, self()}
  end) || _ <- lists:seq(1, NumWriters)],

  %% Start readers that continuously read during writes
  ReaderPids = [spawn_link(fun() ->
    read_loop(M, 100),
    Parent ! {reader_done, self()}
  end) || _ <- lists:seq(1, NumReaders)],

  %% Wait for all writers
  lists:foreach(fun(Pid) ->
    receive {writer_done, Pid} -> ok end
  end, WriterPids),

  %% Signal readers to stop and wait
  lists:foreach(fun(Pid) ->
    receive {reader_done, Pid} -> ok after 5000 -> ok end
  end, ReaderPids),

  %% Final verification
  #{count := FinalCount} = instrument_metric:get_histogram(M),
  ExpectedCount = float(NumWriters * ObservationsPerWriter),
  ?assertEqual(ExpectedCount, FinalCount),
  ok.

read_loop(M, 0) ->
  _ = instrument_metric:get_histogram(M),
  ok;
read_loop(M, N) ->
  #{count := Count, sum := Sum, buckets := Buckets} = instrument_metric:get_histogram(M),
  %% Basic sanity checks - count and sum should be non-negative
  ?assert(Count >= 0),
  ?assert(Sum >= 0),
  ?assert(is_list(Buckets)),
  timer:sleep(10),
  read_loop(M, N - 1).

%% ============================================================================
%% Span Stress Tests
%% ============================================================================

span_high_throughput(_Config) ->
  %% Create/end spans as fast as possible
  NumProcesses = 100,
  SpansPerProcess = 500,

  Results = stress_test(NumProcesses, fun() ->
    lists:foreach(fun(I) ->
      Name = iolist_to_binary([<<"span_">>, integer_to_binary(I)]),
      Span = instrument_tracer:start_span(Name),
      ok = instrument_tracer:set_attribute(<<"index">>, I),
      ok = instrument_tracer:end_span(Span)
    end, lists:seq(1, SpansPerProcess)),
    ok
  end),

  ?assertEqual(NumProcesses, length([ok || ok <- Results])),
  ok.

span_nested_deep(_Config) ->
  %% Deeply nested spans (100+ levels)
  MaxDepth = 100,

  %% Create nested spans
  nested_span_loop(MaxDepth),

  %% Verify no context leaks
  undefined = instrument_tracer:current_span(),
  ok.

nested_span_loop(0) ->
  %% At max depth, do some operations
  ok = instrument_tracer:set_attribute(<<"depth">>, 0),
  ok = instrument_tracer:add_event(<<"at_max_depth">>),
  ok;
nested_span_loop(N) ->
  Name = iolist_to_binary([<<"nested_">>, integer_to_binary(N)]),
  instrument_tracer:with_span(Name, fun() ->
    ok = instrument_tracer:set_attribute(<<"depth">>, N),
    nested_span_loop(N - 1)
  end).

span_concurrent_modifications(_Config) ->
  %% Multiple processes creating spans with modifications concurrently
  %% Tests context isolation and concurrent span lifecycle
  NumProcesses = 100,
  SpansPerProcess = 50,

  Parent = self(),
  Pids = [spawn_link(fun() ->
    lists:foreach(fun(I) ->
      Name = iolist_to_binary([<<"span_">>, integer_to_binary(I)]),
      _Span = instrument_tracer:start_span(Name),

      %% Multiple modifications per span
      lists:foreach(fun(J) ->
        Key = iolist_to_binary([<<"attr_">>, integer_to_binary(J)]),
        ok = instrument_tracer:set_attribute(Key, J),
        ok = instrument_tracer:add_event(iolist_to_binary([<<"event_">>, integer_to_binary(J)]))
      end, lists:seq(1, 10)),

      ok = instrument_tracer:set_status(ok),
      ok = instrument_tracer:end_span()
    end, lists:seq(1, SpansPerProcess)),
    Parent ! {done, self()}
  end) || _ <- lists:seq(1, NumProcesses)],

  %% Wait for all processes
  lists:foreach(fun(Pid) ->
    receive {done, Pid} -> ok after 30000 -> ct:fail({timeout, Pid}) end
  end, Pids),

  %% Verify no context leak
  undefined = instrument_tracer:current_span(),
  ok.

%% ============================================================================
%% Registry Stress Tests
%% ============================================================================

registry_concurrent_register(_Config) ->
  %% Many concurrent registrations with unique names
  NumProcesses = 100,

  Results = stress_test(NumProcesses, fun() ->
    Name = list_to_atom("stress_metric_" ++ integer_to_list(erlang:unique_integer([positive]))),
    _M = instrument_metric:new_counter(Name, <<"concurrent register test">>),
    ok
  end),

  ?assertEqual(NumProcesses, length([ok || ok <- Results])),
  ok.

registry_register_unregister_cycle(_Config) ->
  %% Register/unregister in tight loop
  NumProcesses = 20,
  CyclesPerProcess = 100,

  Results = stress_test(NumProcesses, fun() ->
    BaseName = "cycle_metric_" ++ integer_to_list(erlang:unique_integer([positive])),
    lists:foreach(fun(I) ->
      Name = list_to_atom(BaseName ++ "_" ++ integer_to_list(I)),
      M = instrument_metric:new_counter(Name, <<"cycle test">>),
      ok = instrument_metric:inc_counter(M),
      ok = instrument_metric:unregister(M)
    end, lists:seq(1, CyclesPerProcess)),
    ok
  end),

  ?assertEqual(NumProcesses, length([ok || ok <- Results])),
  ok.
