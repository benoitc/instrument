%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_registry_SUITE).
-author("benoitc").

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("instrument.hrl").

-export([
  all/0,
  init_per_suite/1,
  end_per_suite/1,
  init_per_testcase/2,
  end_per_testcase/2
]).

-export([
  register_unregister_test/1,
  register_duplicate_test/1,
  unregister_all_test/1,
  lookup_test/1,
  collect_all_test/1,
  collect_all_skips_collectorless_test/1,
  concurrent_registration_test/1,
  concurrent_registration_stress_test/1
]).

all() ->
  [
    register_unregister_test,
    register_duplicate_test,
    unregister_all_test,
    lookup_test,
    collect_all_test,
    collect_all_skips_collectorless_test,
    concurrent_registration_test,
    concurrent_registration_stress_test
  ].

init_per_suite(Config) ->
  _ = application:ensure_all_started(crypto),
  ok = application:start(instrument),
  Config.

end_per_suite(_Config) ->
  ok = application:stop(instrument),
  ok.

init_per_testcase(_TestCase, Config) ->
  %% Clean up any existing metrics
  instrument_registry:unregister_all(),
  Config.

end_per_testcase(_TestCase, _Config) ->
  instrument_registry:unregister_all(),
  ok.

%% ============================================================================
%% Test Cases
%% ============================================================================

register_unregister_test(_Config) ->
  %% Create a test metric
  Metric = #metric{
    name = test_metric,
    description = <<"Test metric">>,
    handle = undefined,
    collect = undefined
  },

  %% Register
  ok = instrument_registry:register(Metric),

  %% Verify it can be looked up
  ?assertEqual(Metric, instrument_registry:lookup(test_metric)),

  %% Unregister
  ok = instrument_registry:unregister(test_metric),

  %% Verify it's gone
  ?assertEqual(undefined, instrument_registry:lookup(test_metric)),
  ok.

register_duplicate_test(_Config) ->
  Metric = #metric{
    name = duplicate_metric,
    description = <<"Test metric">>,
    handle = undefined,
    collect = undefined
  },

  %% First registration should succeed
  ok = instrument_registry:register(Metric),

  %% Second registration should fail
  ?assertEqual({error, already_exists}, instrument_registry:register(Metric)),

  %% Cleanup
  ok = instrument_registry:unregister(duplicate_metric),
  ok.

unregister_all_test(_Config) ->
  %% Register multiple metrics
  lists:foreach(fun(N) ->
    Metric = #metric{
      name = list_to_atom("metric_" ++ integer_to_list(N)),
      description = <<"Test metric">>,
      handle = undefined,
      collect = undefined
    },
    ok = instrument_registry:register(Metric)
  end, lists:seq(1, 10)),

  %% Verify they exist
  Names = persistent_term:get(instrument_metrics, []),
  ?assertEqual(10, length(Names)),

  %% Unregister all
  ok = instrument_registry:unregister_all(),

  %% Verify all are gone
  ?assertEqual([], persistent_term:get(instrument_metrics, [])),
  ok.

lookup_test(_Config) ->
  %% Lookup non-existent metric
  ?assertEqual(undefined, instrument_registry:lookup(nonexistent)),

  %% Register and lookup
  Metric = #metric{
    name = lookup_test_metric,
    description = <<"Lookup test">>,
    handle = undefined,
    collect = undefined
  },
  ok = instrument_registry:register(Metric),

  ?assertEqual(Metric, instrument_registry:lookup(lookup_test_metric)),
  ok.

collect_all_test(_Config) ->
  %% Register metric with collector
  Self = self(),
  Metric = #metric{
    name = collectable_metric,
    description = <<"Collectable metric">>,
    handle = undefined,
    collect = {erlang, apply, [fun() ->
      Self ! collector_called,
      #{name => collectable_metric, value => 42}
    end, []]}
  },
  ok = instrument_registry:register(Metric),

  %% Collect all
  Results = instrument_registry:collect_all(),

  %% Verify collector was called
  receive
    collector_called -> ok
  after 1000 ->
    ct:fail(collector_not_called)
  end,

  ?assertEqual([#{name => collectable_metric, value => 42}], Results),
  ok.

%% Regression: a registered record with no collector (collect = undefined) must
%% be skipped, not raise a case_clause that aborts the whole scrape and takes
%% every other metric down with it.
collect_all_skips_collectorless_test(_Config) ->
  Collectable = #metric{
    name = has_collector,
    description = <<"Collectable">>,
    handle = undefined,
    collect = {erlang, apply, [fun() -> #{name => has_collector, value => 7} end, []]}
  },
  Collectorless = #metric{
    name = no_collector,
    description = <<"No collector">>,
    handle = undefined
  },
  ok = instrument_registry:register(Collectable),
  ok = instrument_registry:register(Collectorless),
  Results = instrument_registry:collect_all(),
  ?assertEqual([#{name => has_collector, value => 7}], Results),
  ok.

%% Test concurrent registration to verify no race conditions
concurrent_registration_test(_Config) ->
  NumProcesses = 50,
  Parent = self(),

  %% Spawn processes that register metrics concurrently
  Pids = [spawn_link(fun() ->
    MetricName = list_to_atom("concurrent_metric_" ++ integer_to_list(N)),
    Metric = #metric{
      name = MetricName,
      description = <<"Concurrent test metric">>,
      handle = undefined,
      collect = undefined
    },
    Result = instrument_registry:register(Metric),
    Parent ! {done, self(), MetricName, Result}
  end) || N <- lists:seq(1, NumProcesses)],

  %% Collect results
  Results = [receive
    {done, Pid, Name, Result} -> {Name, Result}
  after 5000 ->
    ct:fail({timeout_waiting_for, Pid})
  end || Pid <- Pids],

  %% All registrations should succeed
  lists:foreach(fun({Name, Result}) ->
    ?assertEqual(ok, Result, io_lib:format("Registration of ~p failed", [Name]))
  end, Results),

  %% Verify all metrics are registered
  Names = persistent_term:get(instrument_metrics, []),
  ?assertEqual(NumProcesses, length(Names)),

  %% Verify no duplicates
  ?assertEqual(length(Names), length(lists:usort(Names))),
  ok.

%% Stress test with higher concurrency
concurrent_registration_stress_test(_Config) ->
  NumProcesses = 200,
  IterationsPerProcess = 5,
  Parent = self(),

  %% Spawn processes that register and unregister metrics
  Pids = [spawn_link(fun() ->
    lists:foreach(fun(Iter) ->
      MetricName = list_to_atom("stress_metric_" ++
        integer_to_list(N) ++ "_" ++ integer_to_list(Iter)),
      Metric = #metric{
        name = MetricName,
        description = <<"Stress test metric">>,
        handle = undefined,
        collect = undefined
      },
      ok = instrument_registry:register(Metric)
    end, lists:seq(1, IterationsPerProcess)),
    Parent ! {done, self()}
  end) || N <- lists:seq(1, NumProcesses)],

  %% Wait for all processes to complete
  lists:foreach(fun(Pid) ->
    receive {done, Pid} -> ok
    after 30000 -> ct:fail({timeout_waiting_for, Pid})
    end
  end, Pids),

  %% Verify correct number of metrics registered
  ExpectedCount = NumProcesses * IterationsPerProcess,
  Names = persistent_term:get(instrument_metrics, []),
  ?assertEqual(ExpectedCount, length(Names)),

  %% Verify no duplicates
  ?assertEqual(length(Names), length(lists:usort(Names))),

  ct:pal("Stress test: ~p metrics registered successfully", [ExpectedCount]),
  ok.
