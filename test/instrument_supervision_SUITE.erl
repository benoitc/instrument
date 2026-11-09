%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc A crashed child of instrument_sup is restarted without taking the
%% application down, and keeps metrics and registrations.
-module(instrument_supervision_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("instrument_otel.hrl").

-export([
  all/0,
  init_per_suite/1,
  end_per_suite/1,
  init_per_testcase/2,
  end_per_testcase/2
]).

-export([
  app_survives_each_child_crash/1,
  registry_crash_keeps_metrics/1,
  log_exporter_crash_keeps_registration/1,
  span_processor_crash_keeps_batch_processor/1,
  too_many_crashes_stop_the_app/1
]).

-define(STUB_TAB, instrument_backpressure_SUITE_stub).
-define(STUB, instrument_backpressure_SUITE_exporter).

all() ->
  [
    app_survives_each_child_crash,
    registry_crash_keeps_metrics,
    log_exporter_crash_keeps_registration,
    span_processor_crash_keeps_batch_processor,
    too_many_crashes_stop_the_app
  ].

init_per_suite(Config) ->
  _ = application:ensure_all_started(crypto),
  Config.

end_per_suite(_Config) ->
  ok.

init_per_testcase(_TC, Config) ->
  ok = application:start(instrument),
  Config.

end_per_testcase(_TC, _Config) ->
  _ = application:stop(instrument),
  ok.

%% ============================================================================

app_survives_each_child_crash(_Config) ->
  Children = [instrument_registry, instrument_exporter, instrument_metrics_exporter,
              instrument_log_exporter, instrument_span_processor,
              instrument_tracer_pool, instrument_flight_recorder],
  lists:foreach(fun(Name) ->
    kill_and_wait(Name),
    ?assert(app_running())
  end, Children),
  ok.

registry_crash_keeps_metrics(_Config) ->
  Meter = instrument_meter:get_meter(<<"supervision_test">>),
  Counter = instrument_meter:create_counter(Meter, <<"supervision_kept">>),
  ok = instrument_meter:add(Counter, 5),
  kill_and_wait(instrument_registry),
  ok = instrument_meter:add(Counter, 2),
  Output = instrument_prometheus:format(),
  ?assertNotEqual(nomatch, binary:match(Output, <<"supervision_kept_total 7.0">>)),
  ok.

log_exporter_crash_keeps_registration(_Config) ->
  Tab = ets:new(supervision_logs, [public, bag]),
  ok = instrument_log_exporter:register(#{module => instrument_test_log_exporter,
                                          config => #{table => Tab}}),
  kill_and_wait(instrument_log_exporter),
  ?assertEqual([instrument_test_log_exporter], instrument_log_exporter:list()),
  ok = instrument_log_exporter:export(#log_record{body = <<"after restart">>}),
  ok = instrument_log_exporter:flush(),
  ?assertMatch([{log, #log_record{body = <<"after restart">>}}], ets:tab2list(Tab)),
  ok.

span_processor_crash_keeps_batch_processor(_Config) ->
  case ets:whereis(?STUB_TAB) of
    undefined -> ets:new(?STUB_TAB, [public, named_table, set]);
    _ -> ets:delete_all_objects(?STUB_TAB)
  end,
  ets:insert(?STUB_TAB, [{inflight, 0}, {sleep_ms, 0}]),
  ok = instrument_span_processor:register(instrument_span_processor_batch,
                                          #{exporter => ?STUB,
                                            schedule_delay_millis => 60000}),
  kill_and_wait(instrument_span_processor),
  %% Re-registration runs right after the manager's init.
  Listed = wait_until(fun instrument_span_processor:list/0,
                      fun(L) -> L =:= [instrument_span_processor_batch] end),
  ?assertEqual([instrument_span_processor_batch], Listed),
  instrument_tracer:with_span(<<"after_restart">>, fun() -> ok end),
  ok = instrument_span_processor_batch:force_flush(),
  ?assertMatch([_ | _], [N || {{call, _}, N} <- ets:tab2list(?STUB_TAB)]),
  ok.

%% More than ten restarts in a minute still stop the application.
too_many_crashes_stop_the_app(_Config) ->
  Ref = monitor(process, whereis(instrument_sup)),
  kill_repeatedly(instrument_log_exporter, 11),
  receive {'DOWN', Ref, process, _, _} -> ok after 30000 -> ct:fail(sup_still_running) end,
  ?assertNot(app_running()),
  ok.

%% ============================================================================

app_running() ->
  lists:keymember(instrument, 1, application:which_applications()).

kill_and_wait(Name) ->
  Old = whereis(Name),
  true = is_pid(Old),
  exit(Old, kill),
  New = wait_until(fun() -> whereis(Name) end,
                   fun(P) -> is_pid(P) andalso P =/= Old end),
  true = is_pid(New) andalso New =/= Old,
  %% Let the children restarted after it finish starting.
  _ = sys:get_state(instrument_sup),
  ok.

%% Kill the process N times, each time waiting for the supervisor to restart
%% it. The name is unregistered while the children after it restart, which
%% can take a while on a slow machine; stop early only once the supervisor
%% itself is gone.
kill_repeatedly(_Name, 0) ->
  ok;
kill_repeatedly(Name, N) ->
  Pid = wait_until(fun() -> whereis(Name) end,
                   fun(P) -> is_pid(P) orelse whereis(instrument_sup) =:= undefined end,
                   10000),
  case is_pid(Pid) of
    true ->
      exit(Pid, kill),
      _ = wait_until(fun() -> whereis(Name) end, fun(P) -> P =/= Pid end, 10000),
      kill_repeatedly(Name, N - 1);
    false ->
      ok
  end.

wait_until(Producer, Pred) ->
  wait_until(Producer, Pred, 3000).

wait_until(Producer, Pred, TimeoutMs) ->
  Result = Producer(),
  case Pred(Result) of
    true -> Result;
    false when TimeoutMs =< 0 -> Result;
    false ->
      timer:sleep(20),
      wait_until(Producer, Pred, TimeoutMs - 20)
  end.
