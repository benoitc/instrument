%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.
-module(instrument_batch_async_SUITE).
-author("benoitc").

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
  all/0,
  init_per_suite/1,
  end_per_suite/1,
  init_per_testcase/2,
  end_per_testcase/2
]).

-export([
  concurrent_force_flush_does_not_serialize/1,
  on_end_not_blocked_by_in_flight_export/1
]).

-define(STUB, instrument_batch_async_SUITE_stub).

all() ->
  [
    concurrent_force_flush_does_not_serialize,
    on_end_not_blocked_by_in_flight_export
  ].

init_per_suite(Config) ->
  Config.

end_per_suite(_Config) ->
  ok.

init_per_testcase(_TC, Config) ->
  reset_stub(),
  try instrument_span_processor_batch:shutdown() catch _:_ -> ok end,
  Config.

end_per_testcase(_TC, _Config) ->
  try instrument_span_processor_batch:shutdown() catch _:_ -> ok end,
  ok.

%% A slow exporter (500ms per call) must not serialize N concurrent
%% force_flush callers. They should all observe roughly one export-window
%% of delay, not N * 500ms.
concurrent_force_flush_does_not_serialize(_) ->
  set_stub_sleep(500),
  {ok, _} = start_batch(#{schedule_delay_millis => 10000,
                          export_timeout_millis => 5000}),
  enqueue_stub_span(),
  %% Let the periodic tick see the queue once so an export starts.
  timer:sleep(50),
  %% Force an explicit flush to start the export if the tick hasn't fired.
  Parent = self(),
  N = 20,
  Start = erlang:monotonic_time(millisecond),
  Pids = [spawn_link(fun() ->
                       instrument_span_processor_batch:force_flush(),
                       Parent ! {done, self()}
                     end) || _ <- lists:seq(1, N)],
  lists:foreach(fun(Pid) ->
    receive {done, Pid} -> ok after 5000 -> erlang:error(flush_timeout) end
  end, Pids),
  Elapsed = erlang:monotonic_time(millisecond) - Start,
  %% With async flush all 20 callers should finish well before serialized
  %% would (20 * 500ms = 10s). Accept < 3s as a generous upper bound that
  %% still catches the old blocking behaviour.
  ?assert(Elapsed < 3000,
          lists:flatten(io_lib:format("elapsed ~p ms not < 3000", [Elapsed]))),
  ok.

%% Casting on_end while the exporter is blocked must not stall; the
%% gen_server loop must continue to accept spans.
on_end_not_blocked_by_in_flight_export(_) ->
  set_stub_sleep(400),
  {ok, _} = start_batch(#{schedule_delay_millis => 10000,
                          export_timeout_millis => 5000,
                          max_export_batch_size => 1}),
  %% First span triggers the max-batch-size immediate export.
  enqueue_stub_span(),
  timer:sleep(50),
  %% Now the worker should be sleeping inside the stub. Additional casts
  %% must be accepted immediately; we time 100 casts.
  Start = erlang:monotonic_time(millisecond),
  [enqueue_stub_span() || _ <- lists:seq(1, 100)],
  Elapsed = erlang:monotonic_time(millisecond) - Start,
  ?assert(Elapsed < 200,
          lists:flatten(io_lib:format("cast loop took ~p ms", [Elapsed]))),
  %% Now block for a force_flush and ensure it still returns.
  instrument_span_processor_batch:force_flush(),
  ok.

%% -------- helpers --------

start_batch(Overrides) ->
  Config = maps:merge(#{exporter => instrument_batch_async_SUITE_exporter,
                        exporter_config => #{},
                        max_queue_size => 10000,
                        max_export_batch_size => 10000,
                        schedule_delay_millis => 10000,
                        export_timeout_millis => 2000,
                        max_batch_retries => 3},
                      Overrides),
  instrument_span_processor_batch:start_link(Config).

enqueue_stub_span() ->
  gen_server:cast(instrument_span_processor_batch,
                  {on_end, {stub_span, make_ref()}}),
  ok.

reset_stub() ->
  case ets:whereis(?STUB) of
    undefined ->
      ets:new(?STUB, [public, named_table, set, {write_concurrency, true}]);
    _ -> ok
  end,
  ets:insert(?STUB, {sleep_ms, 0}),
  ok.

set_stub_sleep(Ms) ->
  reset_stub(),
  ets:insert(?STUB, {sleep_ms, Ms}),
  ok.
