%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Bounded intake and serialized export for the span and log export
%% paths.
-module(instrument_backpressure_SUITE).

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
  default_trace_exporter_uses_batch_processor/1,
  idle_span_exporter_has_no_hook/1,
  span_exporter_mailbox_bounded/1,
  log_exporter_mailbox_bounded/1,
  batch_exports_in_chunks/1,
  batch_flush_outlives_default_call_timeout/1,
  simple_processor_serializes_exports/1
]).

-define(TAB, instrument_backpressure_SUITE_stub).
-define(STUB, instrument_backpressure_SUITE_exporter).

all() ->
  [
    default_trace_exporter_uses_batch_processor,
    idle_span_exporter_has_no_hook,
    span_exporter_mailbox_bounded,
    log_exporter_mailbox_bounded,
    batch_exports_in_chunks,
    batch_flush_outlives_default_call_timeout,
    simple_processor_serializes_exports
  ].

init_per_suite(Config) ->
  _ = application:ensure_all_started(crypto),
  Config.

end_per_suite(_Config) ->
  ok.

init_per_testcase(_TC, Config) ->
  ok = application:start(instrument),
  case ets:whereis(?TAB) of
    undefined -> ets:new(?TAB, [public, named_table, set, {write_concurrency, true}]);
    _ -> ets:delete_all_objects(?TAB)
  end,
  ets:insert(?TAB, [{inflight, 0}, {sleep_ms, 0}]),
  Config.

end_per_testcase(_TC, _Config) ->
  try instrument_span_processor_batch:shutdown() catch _:_ -> ok end,
  ok = application:stop(instrument),
  [os:unsetenv(V) || V <- ["OTEL_TRACES_EXPORTER", "OTEL_EXPORTER_OTLP_ENDPOINT"]],
  ok.

%% ============================================================================

%% A trace exporter from the environment goes through the batch processor;
%% further names go to the span exporter, so no span is exported twice.
default_trace_exporter_uses_batch_processor(_Config) ->
  ok = application:stop(instrument),
  os:putenv("OTEL_TRACES_EXPORTER", "otlp,console"),
  os:putenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318"),
  ok = application:start(instrument),
  ?assertEqual([instrument_span_processor_batch], instrument_span_processor:list()),
  ?assertEqual([instrument_exporter_console], instrument_exporter:list()),
  ok = application:stop(instrument),
  os:putenv("OTEL_TRACES_EXPORTER", "console"),
  ok = application:start(instrument),
  ?assertEqual([instrument_span_processor_batch], instrument_span_processor:list()),
  ?assertEqual([], instrument_exporter:list()),
  ok.

%% With no exporter registered, the tracer does not call the span exporter.
idle_span_exporter_has_no_hook(_Config) ->
  ?assertEqual([], instrument_exporter:list()),
  ?assertEqual([], persistent_term:get('$instrument_exporters', [])),
  ok = instrument_exporter:register(#{module => ?STUB}),
  ?assertMatch([_], persistent_term:get('$instrument_exporters', [])),
  ok = instrument_exporter:unregister(?STUB),
  ?assertEqual([], persistent_term:get('$instrument_exporters', [])),
  ok.

%% While the span exporter cannot keep up, its mailbox stays within the
%% queue limit and the rest is dropped and counted.
span_exporter_mailbox_bounded(_Config) ->
  Pid = whereis(instrument_exporter),
  #{dropped := Before, max_queue := Max} = instrument_exporter:stats(),
  ok = sys:suspend(Pid),
  try
    [instrument_exporter:export_span(#span{}) || _ <- lists:seq(1, Max + 1000)],
    {message_queue_len, Len} = erlang:process_info(Pid, message_queue_len),
    ?assert(Len =< Max),
    #{dropped := After} = instrument_exporter:stats(),
    ?assertEqual(1000, After - Before)
  after
    sys:resume(Pid)
  end,
  ok = instrument_exporter:flush(),
  ?assertEqual(0, maps:get(queued, instrument_exporter:stats())),
  ok.

log_exporter_mailbox_bounded(_Config) ->
  Pid = whereis(instrument_log_exporter),
  #{dropped := Before, max_queue := Max} = instrument_log_exporter:stats(),
  ok = sys:suspend(Pid),
  try
    [instrument_log_exporter:export(#log_record{}) || _ <- lists:seq(1, Max + 500)],
    {message_queue_len, Len} = erlang:process_info(Pid, message_queue_len),
    ?assert(Len =< Max),
    #{dropped := After} = instrument_log_exporter:stats(),
    ?assertEqual(500, After - Before)
  after
    sys:resume(Pid)
  end,
  ok = instrument_log_exporter:flush(),
  ?assertEqual(0, maps:get(queued, instrument_log_exporter:stats())),
  ok.

%% The batch processor exports at most max_export_batch_size spans per call.
batch_exports_in_chunks(_Config) ->
  {ok, _} = start_batch(#{max_export_batch_size => 512, max_queue_size => 4096}),
  [instrument_span_processor_batch:on_end(#span{is_recording = true})
   || _ <- lists:seq(1, 2000)],
  ok = instrument_span_processor_batch:force_flush(),
  Sizes = [N || {{call, _}, N} <- ets:tab2list(?TAB)],
  ?assertEqual(2000, lists:sum(Sizes)),
  ?assert(lists:all(fun(N) -> N =< 512 end, Sizes)),
  ?assert(length(Sizes) >= 4),
  ok.

%% force_flush waits as long as an export may take, not the 5 s call default.
batch_flush_outlives_default_call_timeout(_Config) ->
  ets:insert(?TAB, {sleep_ms, 5500}),
  {ok, _} = start_batch(#{export_timeout_millis => 8000}),
  instrument_span_processor_batch:on_end(#span{is_recording = true}),
  ?assertEqual(ok, instrument_span_processor_batch:force_flush()),
  ?assertMatch([_], [N || {{call, _}, N} <- ets:tab2list(?TAB)]),
  ok.

%% Spans ending concurrently are exported one call at a time.
simple_processor_serializes_exports(_Config) ->
  ets:insert(?TAB, {sleep_ms, 5}),
  ok = instrument_span_processor:register(instrument_span_processor_simple,
                                          #{exporter => ?STUB}),
  try
    Parent = self(),
    Pids = [spawn_link(fun() ->
              instrument_span_processor_simple:on_end(#span{is_recording = true}),
              Parent ! {done, self()}
            end) || _ <- lists:seq(1, 50)],
    [receive {done, P} -> ok after 10000 -> ct:fail(timeout) end || P <- Pids],
    ?assertEqual([], ets:lookup(?TAB, overlap)),
    ?assertEqual(50, length([N || {{call, _}, N} <- ets:tab2list(?TAB)]))
  after
    instrument_span_processor:unregister(instrument_span_processor_simple)
  end.

%% ============================================================================

start_batch(Overrides) ->
  Config = maps:merge(#{exporter => ?STUB,
                        exporter_config => #{},
                        schedule_delay_millis => 60000,
                        export_timeout_millis => 5000},
                      Overrides),
  instrument_span_processor_batch:start_link(Config).
