%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_flight_recorder_SUITE).
-author("benoitc").

-export([
  all/0,
  init_per_suite/1,
  end_per_suite/1,
  init_per_testcase/2,
  end_per_testcase/2
]).

-export([
  basic_enable_disable/1,
  capture_span_events/1,
  capture_cross_process_messages/1,
  marker_events/1,
  get_trace_by_id/1,
  dump_trace_clears/1,
  buffer_eviction/1,
  stats_reporting/1,
  trace_propagation/1,
  disabled_no_capture/1
]).

-include("instrument_otel.hrl").

all() ->
  [
    basic_enable_disable,
    capture_span_events,
    capture_cross_process_messages,
    marker_events,
    get_trace_by_id,
    dump_trace_clears,
    buffer_eviction,
    stats_reporting,
    trace_propagation,
    disabled_no_capture
  ].

init_per_suite(Config) ->
  _ = application:ensure_all_started(crypto),
  %% Set auto_enable to false so we can control it in tests
  application:set_env(instrument, flight_recorder_auto_enable, false),
  ok = application:start(instrument),
  Config.

end_per_suite(Config) ->
  ok = application:stop(instrument),
  Config.

init_per_testcase(_, Config) ->
  %% Clean up context between tests
  erlang:erase('$instrument_context'),
  erlang:erase('$instrument_flight_label'),
  %% Disable any existing trace on this process
  catch erlang:trace(self(), false, [send, 'receive']),
  %% Clear flight recorder buffer
  catch instrument_flight_recorder:clear(),
  Config.

end_per_testcase(_, _Config) ->
  erlang:erase('$instrument_context'),
  erlang:erase('$instrument_flight_label'),
  %% Disable any existing trace on this process
  catch erlang:trace(self(), false, [send, 'receive']),
  %% Disable and clear after each test
  catch instrument_flight_recorder:disable(),
  catch instrument_flight_recorder:clear(),
  ok.

%% ============================================================================
%% Test Cases
%% ============================================================================

basic_enable_disable(_Config) ->
  %% Initially disabled (due to auto_enable = false)
  false = instrument_flight_recorder:is_enabled(),

  %% Enable
  ok = instrument_flight_recorder:enable(),
  true = instrument_flight_recorder:is_enabled(),

  %% Disable
  ok = instrument_flight_recorder:disable(),
  false = instrument_flight_recorder:is_enabled(),
  ok.

capture_span_events(_Config) ->
  ok = instrument_flight_recorder:enable(),

  %% Create a span and send a message within it
  instrument_tracer:with_span(<<"test_span">>, fun() ->
    %% Send a message to self
    self() ! test_message,
    receive test_message -> ok end
  end),

  %% Wait for worker to flush events (flush interval is 50ms)
  timer:sleep(100),

  %% Should have captured events
  Events = instrument_flight_recorder:dump_all(),
  ct:pal("Captured events: ~p", [Events]),
  true = length(Events) >= 2,  %% At least send + receive
  ok.

capture_cross_process_messages(_Config) ->
  ok = instrument_flight_recorder:enable(),
  Parent = self(),

  instrument_tracer:with_span(<<"parent_span">>, fun() ->
    TraceIdHex = instrument_tracer:trace_id(),
    TraceIdBin = instrument_id:hex_to_trace_id(TraceIdHex),

    %% Spawn a child process that sends a message back
    spawn(fun() ->
      Parent ! {child_response, ok}
    end),

    receive
      {child_response, ok} -> ok
    after 1000 ->
      ct:fail(timeout)
    end,

    %% Wait for worker to flush events (flush interval is 50ms)
    timer:sleep(100),
    Events = instrument_flight_recorder:get_trace(TraceIdBin),
    ct:pal("Cross-process events: ~p", [Events]),
    %% Should have at least send + receive events
    true = length(Events) >= 2
  end),
  ok.

marker_events(_Config) ->
  ok = instrument_flight_recorder:enable(),

  instrument_tracer:with_span(<<"marker_test">>, fun() ->
    TraceIdHex = instrument_tracer:trace_id(),
    TraceIdBin = instrument_id:hex_to_trace_id(TraceIdHex),

    %% Add custom markers
    ok = instrument_flight_recorder:mark(<<"request_start">>),
    ok = instrument_flight_recorder:mark(<<"db_query">>, #{table => users}),
    ok = instrument_flight_recorder:mark(<<"request_end">>, #{status => 200}),

    %% Markers are inserted directly to ETS, no flush needed
    timer:sleep(10),
    Events = instrument_flight_recorder:get_trace(TraceIdBin),
    ct:pal("Marker events: ~p", [Events]),

    %% Find marker events
    Markers = [E || {_, E} <- Events, element(1, E) =:= marker],
    ct:pal("Markers: ~p", [Markers]),
    true = length(Markers) >= 3
  end),
  ok.

get_trace_by_id(_Config) ->
  ok = instrument_flight_recorder:enable(),

  %% Create two separate traces
  TraceId1 = instrument_tracer:with_span(<<"trace1">>, fun() ->
    TraceIdHex = instrument_tracer:trace_id(),
    instrument_flight_recorder:mark(<<"trace1_marker">>),
    instrument_id:hex_to_trace_id(TraceIdHex)
  end),

  TraceId2 = instrument_tracer:with_span(<<"trace2">>, fun() ->
    TraceIdHex = instrument_tracer:trace_id(),
    instrument_flight_recorder:mark(<<"trace2_marker">>),
    instrument_id:hex_to_trace_id(TraceIdHex)
  end),

  timer:sleep(10),

  %% Get events for each trace separately
  Events1 = instrument_flight_recorder:get_trace(TraceId1),
  Events2 = instrument_flight_recorder:get_trace(TraceId2),

  ct:pal("Trace1 events: ~p", [Events1]),
  ct:pal("Trace2 events: ~p", [Events2]),

  %% Each trace should have at least one marker
  true = length(Events1) >= 1,
  true = length(Events2) >= 1,

  %% Verify events are from correct traces
  true = lists:any(fun({_, {marker, <<"trace1_marker">>, _}}) -> true; (_) -> false end, Events1),
  true = lists:any(fun({_, {marker, <<"trace2_marker">>, _}}) -> true; (_) -> false end, Events2),
  ok.

dump_trace_clears(_Config) ->
  ok = instrument_flight_recorder:enable(),

  TraceId = instrument_tracer:with_span(<<"dump_test">>, fun() ->
    TraceIdHex = instrument_tracer:trace_id(),
    instrument_flight_recorder:mark(<<"test_marker">>),
    instrument_id:hex_to_trace_id(TraceIdHex)
  end),

  timer:sleep(10),

  %% First dump should return events
  Events1 = instrument_flight_recorder:dump_trace(TraceId),
  ct:pal("First dump: ~p", [Events1]),
  true = length(Events1) >= 1,

  %% Second dump should return empty (events cleared)
  Events2 = instrument_flight_recorder:dump_trace(TraceId),
  ct:pal("Second dump: ~p", [Events2]),
  0 = length(Events2),
  ok.

buffer_eviction(_Config) ->
  ok = instrument_flight_recorder:enable(),

  %% Clear any existing events
  ok = instrument_flight_recorder:clear(),

  %% Set small buffer size for testing
  ok = instrument_flight_recorder:set_buffer_size(10),

  %% Generate more events than buffer size
  instrument_tracer:with_span(<<"eviction_test">>, fun() ->
    lists:foreach(fun(N) ->
      instrument_flight_recorder:mark(<<"marker">>, #{n => N})
    end, lists:seq(1, 20))
  end),

  %% Wait for eviction (runs every 1000ms)
  timer:sleep(1500),

  %% Buffer should not exceed max size by much
  Stats = instrument_flight_recorder:stats(),
  ct:pal("Stats after overflow: ~p", [Stats]),
  TableSize = maps:get(table_size, Stats),
  true = TableSize =< 15,  %% Allow some margin for async eviction

  %% Reset buffer size to default
  ok = instrument_flight_recorder:set_buffer_size(65536),
  ok.

stats_reporting(_Config) ->
  ok = instrument_flight_recorder:enable(),

  %% Initial stats
  Stats1 = instrument_flight_recorder:stats(),
  ct:pal("Initial stats: ~p", [Stats1]),
  true = maps:get(enabled, Stats1),
  true = is_integer(maps:get(buffer_size, Stats1)),

  %% Add some events (markers go directly to ETS)
  instrument_tracer:with_span(<<"stats_test">>, fun() ->
    instrument_flight_recorder:mark(<<"marker1">>),
    instrument_flight_recorder:mark(<<"marker2">>)
  end),

  %% Markers are inserted directly to ETS
  timer:sleep(10),

  %% Stats should show events
  Stats2 = instrument_flight_recorder:stats(),
  ct:pal("Stats after events: ~p", [Stats2]),
  true = maps:get(table_size, Stats2) >= 2,
  ok.

trace_propagation(_Config) ->
  ok = instrument_flight_recorder:enable(),
  Parent = self(),

  instrument_tracer:with_span(<<"propagation_test">>, fun() ->
    TraceIdHex = instrument_tracer:trace_id(),
    TraceIdBin = instrument_id:hex_to_trace_id(TraceIdHex),

    %% Spawn process that sends a message (set_on_spawn should propagate tracing)
    Pid = spawn(fun() ->
      %% Process should be traced via set_on_spawn
      %% Send a message to trigger trace event
      Parent ! {child_ready, self()}
    end),

    %% Wait for child message
    receive
      {child_ready, ChildPid} ->
        ct:pal("Received child ready from ~p", [ChildPid]),
        true = ChildPid =:= Pid
    after 1000 ->
      ct:fail(timeout)
    end,

    %% Give trace events time to be processed
    timer:sleep(50),

    %% Check that events from child process were captured
    Events = instrument_flight_recorder:get_trace(TraceIdBin),
    ct:pal("Trace events: ~p", [Events]),

    %% Verify we have events (send from child, receive by parent)
    true = length(Events) >= 1
  end),
  ok.

disabled_no_capture(_Config) ->
  %% Ensure disabled
  ok = instrument_flight_recorder:disable(),
  false = instrument_flight_recorder:is_enabled(),

  instrument_tracer:with_span(<<"disabled_test">>, fun() ->
    %% These should be no-ops when disabled
    ok = instrument_flight_recorder:mark(<<"should_not_capture">>),
    self() ! test_message,
    receive test_message -> ok end
  end),

  %% Wait for any potential events to be flushed
  timer:sleep(100),

  %% Should have no events (tracing is disabled)
  AllEvents = instrument_flight_recorder:dump_all(),
  ct:pal("Events when disabled: ~p", [AllEvents]),
  %% No events should be captured when disabled
  0 = length(AllEvents),
  ok.
