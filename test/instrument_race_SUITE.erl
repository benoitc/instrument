%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_race_SUITE).
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

%% Context race tests
-export([
  context_attach_detach_race/1,
  context_spawn_race/1
]).

%% Registry race tests
-export([
  registry_double_register/1,
  registry_unregister_during_use/1,
  vector_label_creation_race/1
]).

%% Span race tests
-export([
  span_concurrent_attribute_update/1,
  span_end_during_modification/1,
  exporter_register_during_export/1
]).

%% Batch processor race tests
-export([
  batch_overflow_race/1,
  batch_shutdown_during_export/1,
  batch_flush_during_batch/1
]).

%% Propagator race tests
-export([
  propagator_register_during_inject/1
]).

all() ->
  [{group, race}].

groups() ->
  [
    {race, [sequence], [
      context_attach_detach_race,
      context_spawn_race,
      registry_double_register,
      registry_unregister_during_use,
      vector_label_creation_race,
      span_concurrent_attribute_update,
      span_end_during_modification,
      exporter_register_during_export,
      batch_overflow_race,
      batch_shutdown_during_export,
      batch_flush_during_batch,
      propagator_register_during_inject
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
  %% Clean up processors
  lists:foreach(fun(M) ->
    catch instrument_span_processor:unregister(M)
  end, instrument_span_processor:list()),
  Config.

end_per_testcase(_TestCase, _Config) ->
  %% Clean up any registered metrics
  catch instrument:unregister_all(),
  %% Clean up processors
  lists:foreach(fun(M) ->
    catch instrument_span_processor:unregister(M)
  end, instrument_span_processor:list()),
  %% Clear context
  erlang:erase('$instrument_context'),
  ok.

%% ============================================================================
%% Race Test Helpers
%% ============================================================================

%% Run two operations concurrently, verify no crash/corruption
race_test(Op1, Op2) ->
  Parent = self(),
  P1 = spawn_link(fun() -> Op1(), Parent ! {self(), done} end),
  P2 = spawn_link(fun() -> Op2(), Parent ! {self(), done} end),
  receive {P1, done} -> ok after 10000 -> ct:fail({timeout, p1}) end,
  receive {P2, done} -> ok after 10000 -> ct:fail({timeout, p2}) end.

%% Run N operations concurrently
race_test_n(Ops) ->
  Parent = self(),
  Pids = [spawn_link(fun() -> Op(), Parent ! {self(), done} end) || Op <- Ops],
  lists:foreach(fun(Pid) ->
    receive {Pid, done} -> ok after 10000 -> ct:fail({timeout, Pid}) end
  end, Pids).

%% ============================================================================
%% Context Race Tests
%% ============================================================================

context_attach_detach_race(_Config) ->
  %% Concurrent attach/detach from multiple processes
  NumIterations = 100,

  lists:foreach(fun(_) ->
    race_test(
      fun() ->
        Ctx = instrument_context:set_value(instrument_context:new(), key1, value1),
        Token = instrument_context:attach(Ctx),
        %% Small work
        _ = instrument_context:current(),
        instrument_context:detach(Token)
      end,
      fun() ->
        Ctx = instrument_context:set_value(instrument_context:new(), key2, value2),
        Token = instrument_context:attach(Ctx),
        _ = instrument_context:current(),
        instrument_context:detach(Token)
      end
    )
  end, lists:seq(1, NumIterations)),
  ok.

context_spawn_race(_Config) ->
  %% Context modification during spawn
  NumIterations = 50,

  lists:foreach(fun(_) ->
    Parent = self(),
    Ctx = instrument_context:set_value(instrument_context:new(), spawn_key, spawn_value),
    _ = instrument_context:attach(Ctx),

    %% Start multiple spawns while modifying context
    Pids = lists:map(fun(_) ->
      instrument_context:spawn_with_context(fun() ->
        %% Check we got the context
        Current = instrument_context:current(),
        Value = instrument_context:get_value(Current, spawn_key),
        Parent ! {self(), Value}
      end)
    end, lists:seq(1, 10)),

    %% Modify context while spawns are in flight
    Ctx2 = instrument_context:set_value(instrument_context:current(), spawn_key, new_value),
    instrument_context:set_current(Ctx2),

    %% All spawned processes should have gotten a value (old or new)
    lists:foreach(fun(Pid) ->
      receive
        {Pid, Value} ->
          ?assert(Value =:= spawn_value orelse Value =:= new_value orelse Value =:= undefined)
      after 5000 ->
        ct:fail({spawn_timeout, Pid})
      end
    end, Pids)
  end, lists:seq(1, NumIterations)),
  ok.

%% ============================================================================
%% Registry Race Tests
%% ============================================================================

registry_double_register(_Config) ->
  %% Two processes try to register same metric simultaneously
  NumIterations = 50,

  lists:foreach(fun(I) ->
    Name = list_to_atom("race_counter_" ++ integer_to_list(I)),
    Parent = self(),

    %% Two processes try to register same metric
    P1 = spawn(fun() ->
      R = try
        instrument:new_counter(Name, <<"test">>)
      catch
        _:E -> {error, E}
      end,
      Parent ! {self(), R}
    end),
    P2 = spawn(fun() ->
      R = try
        instrument:new_counter(Name, <<"test">>)
      catch
        _:E -> {error, E}
      end,
      Parent ! {self(), R}
    end),

    R1 = receive {P1, Res1} -> Res1 end,
    R2 = receive {P2, Res2} -> Res2 end,

    %% At least one should succeed, and both should be consistent
    %% (either same metric or one errors)
    HasSuccess = case {R1, R2} of
      {{error, _}, {error, _}} -> false;
      _ -> true
    end,
    ?assert(HasSuccess),

    %% Clean up
    catch instrument:unregister(Name)
  end, lists:seq(1, NumIterations)),
  ok.

registry_unregister_during_use(_Config) ->
  %% Unregister while metric is being used
  NumIterations = 20,

  lists:foreach(fun(I) ->
    Name = list_to_atom("unreg_counter_" ++ integer_to_list(I)),
    M = instrument:new_counter(Name, <<"test">>),

    Parent = self(),

    %% One process uses the metric
    UserPid = spawn_link(fun() ->
      lists:foreach(fun(_) ->
        try
          instrument:inc_counter(M)
        catch
          _:_ -> ok
        end,
        timer:sleep(1)
      end, lists:seq(1, 100)),
      Parent ! {self(), done}
    end),

    %% Another process unregisters it mid-use
    timer:sleep(10),
    UnregPid = spawn_link(fun() ->
      instrument:unregister(M),
      Parent ! {self(), done}
    end),

    %% Both should complete without crash
    receive {UserPid, done} -> ok after 5000 -> ct:fail(user_timeout) end,
    receive {UnregPid, done} -> ok after 5000 -> ct:fail(unreg_timeout) end
  end, lists:seq(1, NumIterations)),
  ok.

vector_label_creation_race(_Config) ->
  %% Concurrent label creation for same labels
  _Vec = instrument:new_counter_vec(race_vec, <<"race test">>, [method, status]),

  NumProcesses = 50,
  Parent = self(),

  %% Many processes try to create same labels
  Pids = [spawn_link(fun() ->
    lists:foreach(fun(I) ->
      Method = list_to_binary(["method_", integer_to_list(I rem 5)]),
      Status = list_to_binary(["status_", integer_to_list(I rem 3)]),
      try
        instrument:inc_counter_vec(race_vec, [Method, Status])
      catch
        _:_ -> ok
      end
    end, lists:seq(1, 100)),
    Parent ! {self(), done}
  end) || _ <- lists:seq(1, NumProcesses)],

  lists:foreach(fun(Pid) ->
    receive {Pid, done} -> ok after 10000 -> ct:fail({timeout, Pid}) end
  end, Pids),
  ok.

%% ============================================================================
%% Span Race Tests
%% ============================================================================

span_concurrent_attribute_update(_Config) ->
  %% Multiple processes creating and modifying spans concurrently
  NumProcesses = 100,

  race_test_n([fun() ->
    Span = instrument_tracer:start_span(<<"race_span">>),
    lists:foreach(fun(I) ->
      Key = iolist_to_binary([<<"key_">>, integer_to_binary(I)]),
      instrument_tracer:set_attribute(Key, I)
    end, lists:seq(1, 50)),
    instrument_tracer:end_span(Span)
  end || _ <- lists:seq(1, NumProcesses)]),
  ok.

span_end_during_modification(_Config) ->
  %% End span while modifying it (in same process, tight race)
  NumIterations = 100,

  lists:foreach(fun(_) ->
    Span = instrument_tracer:start_span(<<"end_race_span">>),

    %% Spawn modifier that tries to beat end_span
    Parent = self(),
    ModPid = spawn_link(fun() ->
      lists:foreach(fun(I) ->
        try
          instrument_tracer:set_attribute(<<"attr">>, I)
        catch
          _:_ -> ok
        end
      end, lists:seq(1, 10)),
      Parent ! {self(), done}
    end),

    %% End span while modifier is running
    instrument_tracer:end_span(Span),

    receive {ModPid, done} -> ok after 5000 -> ok end
  end, lists:seq(1, NumIterations)),
  ok.

exporter_register_during_export(_Config) ->
  %% Register exporter while spans are being exported
  Parent = self(),

  %% Create a slow exporter
  SlowExporter = fun(_Span) ->
    timer:sleep(50),
    ok
  end,

  ok = instrument_tracer:register_exporter(SlowExporter),

  %% Spawn span creators
  CreatorPids = [spawn_link(fun() ->
    lists:foreach(fun(I) ->
      Name = iolist_to_binary([<<"export_race_">>, integer_to_binary(I)]),
      instrument_tracer:with_span(Name, fun() ->
        timer:sleep(1)
      end)
    end, lists:seq(1, 20)),
    Parent ! {self(), done}
  end) || _ <- lists:seq(1, 5)],

  %% While exports are happening, register/unregister exporters
  RegPid = spawn_link(fun() ->
    lists:foreach(fun(_) ->
      NewExporter = fun(_) -> ok end,
      instrument_tracer:register_exporter(NewExporter),
      timer:sleep(10),
      instrument_tracer:unregister_exporter(NewExporter)
    end, lists:seq(1, 10)),
    Parent ! {self(), done}
  end),

  %% Wait for all
  lists:foreach(fun(Pid) ->
    receive {Pid, done} -> ok after 30000 -> ct:fail({timeout, Pid}) end
  end, [RegPid | CreatorPids]),

  instrument_tracer:unregister_exporter(SlowExporter),
  ok.

%% ============================================================================
%% Batch Processor Race Tests
%% ============================================================================

batch_overflow_race(_Config) ->
  %% Queue overflow under high load
  meck:new(overflow_exporter, [non_strict]),
  meck:expect(overflow_exporter, init, fun(_) -> {ok, #{}} end),
  meck:expect(overflow_exporter, export, fun(Spans, State) ->
    %% Fast export, just count
    {ok, State#{count => maps:get(count, State, 0) + length(Spans)}}
  end),
  meck:expect(overflow_exporter, shutdown, fun(_) -> ok end),

  ok = instrument_span_processor:register(instrument_span_processor_batch, #{
    exporter => overflow_exporter,
    max_queue_size => 100,
    max_export_batch_size => 50,
    schedule_delay_millis => 10
  }),

  %% Flood with spans
  NumProcesses = 20,
  SpansPerProcess = 50,
  Parent = self(),

  Pids = [spawn_link(fun() ->
    lists:foreach(fun(I) ->
      Name = iolist_to_binary([<<"overflow_">>, integer_to_binary(I)]),
      Span = instrument_tracer:start_span(Name),
      instrument_tracer:end_span(Span)
    end, lists:seq(1, SpansPerProcess)),
    Parent ! {self(), done}
  end) || _ <- lists:seq(1, NumProcesses)],

  %% All should complete without crash
  lists:foreach(fun(Pid) ->
    receive {Pid, done} -> ok after 30000 -> ct:fail({timeout, Pid}) end
  end, Pids),

  %% Wait a bit for exports to complete before unregistering
  timer:sleep(500),

  instrument_span_processor:unregister(instrument_span_processor_batch),
  meck:unload(overflow_exporter),
  ok.

batch_shutdown_during_export(_Config) ->
  %% Shutdown during active export - test that shutdown is graceful
  meck:new(shutdown_race_exporter, [non_strict]),
  meck:expect(shutdown_race_exporter, init, fun(_) -> {ok, #{}} end),
  meck:expect(shutdown_race_exporter, export, fun(_Spans, State) ->
    timer:sleep(20),
    {ok, State}
  end),
  meck:expect(shutdown_race_exporter, shutdown, fun(_) -> ok end),

  ok = instrument_span_processor:register(instrument_span_processor_batch, #{
    exporter => shutdown_race_exporter,
    max_export_batch_size => 5,
    schedule_delay_millis => 10
  }),

  %% Create some spans
  lists:foreach(fun(I) ->
    Name = iolist_to_binary([<<"shutdown_race_">>, integer_to_binary(I)]),
    Span = instrument_tracer:start_span(Name),
    instrument_tracer:end_span(Span)
  end, lists:seq(1, 10)),

  %% Give time for export to start
  timer:sleep(50),

  %% Shutdown during export - should complete gracefully
  ok = instrument_span_processor:unregister(instrument_span_processor_batch),

  meck:unload(shutdown_race_exporter),
  ok.

batch_flush_during_batch(_Config) ->
  %% Concurrent flush and batch export
  meck:new(flush_race_exporter, [non_strict]),
  meck:expect(flush_race_exporter, init, fun(_) -> {ok, #{}} end),
  meck:expect(flush_race_exporter, export, fun(_Spans, State) ->
    timer:sleep(10),
    {ok, State}
  end),
  meck:expect(flush_race_exporter, shutdown, fun(_) -> ok end),

  ok = instrument_span_processor:register(instrument_span_processor_batch, #{
    exporter => flush_race_exporter,
    max_export_batch_size => 10,
    schedule_delay_millis => 50
  }),

  Parent = self(),

  %% Span creator
  CreatorPid = spawn_link(fun() ->
    lists:foreach(fun(I) ->
      Name = iolist_to_binary([<<"flush_race_">>, integer_to_binary(I)]),
      Span = instrument_tracer:start_span(Name),
      instrument_tracer:end_span(Span),
      timer:sleep(5)
    end, lists:seq(1, 30)),
    Parent ! {self(), done}
  end),

  %% Flusher
  FlusherPid = spawn_link(fun() ->
    lists:foreach(fun(_) ->
      catch instrument_span_processor:force_flush(),
      timer:sleep(30)
    end, lists:seq(1, 5)),
    Parent ! {self(), done}
  end),

  receive {CreatorPid, done} -> ok after 30000 -> ct:fail(creator_timeout) end,
  receive {FlusherPid, done} -> ok after 30000 -> ct:fail(flusher_timeout) end,

  %% Wait for exports to drain
  timer:sleep(200),

  instrument_span_processor:unregister(instrument_span_processor_batch),
  meck:unload(flush_race_exporter),
  ok.

%% ============================================================================
%% Propagator Race Tests
%% ============================================================================

propagator_register_during_inject(_Config) ->
  %% Register propagator during inject/extract operations
  NumIterations = 50,

  lists:foreach(fun(_) ->
    %% Start a span for context
    Span = instrument_tracer:start_span(<<"propagator_race">>),

    race_test(
      fun() ->
        lists:foreach(fun(_) ->
          try
            Carrier = instrument_propagation:inject(#{}),
            _ = instrument_propagation:extract(Carrier)
          catch
            _:_ -> ok
          end
        end, lists:seq(1, 10))
      end,
      fun() ->
        %% Simulate propagator changes (via baggage changes)
        lists:foreach(fun(I) ->
          try
            Key = list_to_atom("key_" ++ integer_to_list(I)),
            instrument_baggage:set(Key, <<"value">>),
            instrument_baggage:remove(Key)
          catch
            _:_ -> ok
          end
        end, lists:seq(1, 10))
      end
    ),

    instrument_tracer:end_span(Span)
  end, lists:seq(1, NumIterations)),
  ok.
