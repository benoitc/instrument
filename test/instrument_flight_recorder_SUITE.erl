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
  disabled_no_capture/1,
  %% New tests for edge cases
  enable_idempotent/1,
  trace_flags_cleared_after_span/1,
  async_parent_span_traced/1,
  marker_in_spawned_child/1,
  tracer_bootstrap_filtered/1
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
    disabled_no_capture,
    %% Edge case tests
    enable_idempotent,
    trace_flags_cleared_after_span,
    async_parent_span_traced,
    marker_in_spawned_child,
    tracer_bootstrap_filtered
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
    ChildPid = spawn(fun() ->
      %% Process should be traced via set_on_spawn
      %% Send a message to trigger trace event
      Parent ! {child_ready, self()}
    end),

    %% Wait for child message
    receive
      {child_ready, ReceivedPid} ->
        ct:pal("Received child ready from ~p", [ReceivedPid]),
        true = ReceivedPid =:= ChildPid
    after 1000 ->
      ct:fail(timeout)
    end,

    %% Give trace events time to be processed (flush interval is 50ms)
    timer:sleep(100),

    %% Check that events from child process were captured
    Events = instrument_flight_recorder:get_trace(TraceIdBin),
    ct:pal("Trace events: ~p", [Events]),

    %% Verify we have events and specifically that child's send was captured
    %% Event format: {Timestamp, {send, SenderPid, Msg, ReceiverPid}}
    ChildSendEvents = [E || {_, E} <- Events,
                            is_tuple(E),
                            tuple_size(E) >= 2,
                            element(1, E) =:= send,
                            element(2, E) =:= ChildPid],
    ct:pal("Child send events: ~p", [ChildSendEvents]),
    true = length(ChildSendEvents) >= 1
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

enable_idempotent(_Config) ->
  %% Test that enable/0 is idempotent and doesn't leak workers
  ok = instrument_flight_recorder:enable(),
  Stats1 = instrument_flight_recorder:stats(),
  PoolSize1 = maps:get(pool_size, Stats1),
  ct:pal("Pool size after first enable: ~p", [PoolSize1]),

  %% Enable again - should not create more workers
  ok = instrument_flight_recorder:enable(),
  ok = instrument_flight_recorder:enable(),
  ok = instrument_flight_recorder:enable(),

  Stats2 = instrument_flight_recorder:stats(),
  PoolSize2 = maps:get(pool_size, Stats2),
  ct:pal("Pool size after multiple enables: ~p", [PoolSize2]),

  %% Pool size should be the same
  PoolSize1 = PoolSize2,

  %% Check actual worker count via supervisor
  Children = supervisor:which_children(instrument_tracer_pool),
  ct:pal("Worker count: ~p", [length(Children)]),
  true = length(Children) =:= PoolSize1,
  ok.

trace_flags_cleared_after_span(_Config) ->
  %% Test that trace flags are fully cleared after span ends
  ok = instrument_flight_recorder:enable(),

  %% Start and end a span
  instrument_tracer:with_span(<<"test_span">>, fun() ->
    %% Verify tracing is active
    {flags, Flags} = erlang:trace_info(self(), flags),
    ct:pal("Flags during span: ~p", [Flags]),
    true = lists:member(send, Flags),
    true = lists:member('receive', Flags)
  end),

  %% After span ends, trace flags should be cleared
  {flags, FlagsAfter} = erlang:trace_info(self(), flags),
  ct:pal("Flags after span: ~p", [FlagsAfter]),

  %% Should have no trace flags
  false = lists:member(send, FlagsAfter),
  false = lists:member('receive', FlagsAfter),
  false = lists:member(set_on_spawn, FlagsAfter),

  %% Tracer should be cleared too
  {tracer, TracerAfter} = erlang:trace_info(self(), tracer),
  ct:pal("Tracer after span: ~p", [TracerAfter]),
  [] = TracerAfter,
  ok.

async_parent_span_traced(_Config) ->
  %% Test that a pre-existing worker process using #{parent => SpanCtx}
  %% gets traced and its events are captured
  ok = instrument_flight_recorder:enable(),
  Parent = self(),

  %% Start a long-lived worker process BEFORE any span
  Worker = spawn(fun() ->
    worker_loop(Parent)
  end),

  %% Create a root span and get its context
  SpanCtx = instrument_tracer:with_span(<<"root_span">>, fun() ->
    instrument_tracer:span_ctx()
  end),

  %% Clear any events from root span
  timer:sleep(100),
  _ = instrument_flight_recorder:clear(),

  %% Now tell worker to create a child span with the parent context
  Worker ! {start_span, SpanCtx},
  receive
    {span_done, TraceIdBin} ->
      ct:pal("Worker finished span, trace_id: ~p", [TraceIdBin]),

      %% Wait for events to flush
      timer:sleep(100),

      %% Get events for this trace
      Events = instrument_flight_recorder:get_trace(TraceIdBin),
      ct:pal("Async parent events: ~p", [Events]),

      %% Should have events from the worker process
      %% At minimum: the worker's send and receive for the done message
      true = length(Events) >= 1,

      %% Verify worker's trace flags are cleared
      Worker ! check_flags,
      receive
        {flags_result, WorkerFlags} ->
          ct:pal("Worker flags after span: ~p", [WorkerFlags]),
          false = lists:member(send, WorkerFlags),
          false = lists:member('receive', WorkerFlags)
      after 1000 ->
        ct:fail(timeout_flags)
      end
  after 5000 ->
    ct:fail(timeout_span)
  end,

  Worker ! stop,
  ok.

%% Helper for async_parent_span_traced test
worker_loop(Parent) ->
  receive
    {start_span, SpanCtx} ->
      %% Start a span with the given parent context
      instrument_tracer:with_span(<<"worker_span">>, #{parent => SpanCtx}, fun() ->
        TraceIdHex = instrument_tracer:trace_id(),
        TraceIdBin = instrument_id:hex_to_trace_id(TraceIdHex),
        %% Send a message to generate trace event
        Parent ! {span_done, TraceIdBin}
      end),
      worker_loop(Parent);
    check_flags ->
      {flags, Flags} = erlang:trace_info(self(), flags),
      Parent ! {flags_result, Flags},
      worker_loop(Parent);
    stop ->
      ok
  end.

marker_in_spawned_child(_Config) ->
  %% Test that mark/1,2 works in spawned children that inherit tracing
  %% via set_on_spawn (they don't have label in process dict, but can
  %% extract it from tracer state)
  ok = instrument_flight_recorder:enable(),
  Parent = self(),

  instrument_tracer:with_span(<<"parent_span">>, fun() ->
    TraceIdHex = instrument_tracer:trace_id(),
    TraceIdBin = instrument_id:hex_to_trace_id(TraceIdHex),

    %% Spawn a child process (inherits tracing via set_on_spawn)
    spawn(fun() ->
      %% Add a marker in the child process
      ok = instrument_flight_recorder:mark(<<"child_marker">>, #{from => child}),
      Parent ! child_done
    end),

    receive child_done -> ok after 1000 -> ct:fail(timeout) end,

    %% Wait for events to flush
    timer:sleep(100),

    %% Get events for this trace
    Events = instrument_flight_recorder:get_trace(TraceIdBin),
    ct:pal("Events with child marker: ~p", [Events]),

    %% Find the child marker
    Markers = [E || {_, E} <- Events, element(1, E) =:= marker],
    ct:pal("Markers found: ~p", [Markers]),

    %% Should have at least one marker from the child
    true = length(Markers) >= 1,

    %% Verify it's the child marker
    true = lists:any(fun({marker, <<"child_marker">>, #{from := child}}) -> true;
                        (_) -> false
                     end, Markers)
  end),
  ok.

tracer_bootstrap_filtered(_Config) ->
  %% Test that internal tracer bootstrap messages are filtered out
  %% When set_on_spawn propagates tracing, spawned children receive
  %% internal messages like {Ref, {tracer, {instrument_tracer_nif, _}}}
  %% which should not appear in trace output
  ok = instrument_flight_recorder:enable(),
  instrument_flight_recorder:clear(),

  %% Start span and spawn child, capturing the actual trace ID
  TraceIdBin = instrument_tracer:with_span(<<"parent">>, fun() ->
    TraceIdHex = instrument_tracer:trace_id(),
    TraceId = instrument_id:hex_to_trace_id(TraceIdHex),

    %% Spawn child - this triggers tracer bootstrap message
    Child = spawn(fun() ->
      %% Child sends a normal message to itself
      self() ! <<"normal_msg">>,
      receive <<"normal_msg">> -> ok end,
      timer:sleep(10)
    end),
    timer:sleep(100),
    exit(Child, kill),
    TraceId
  end),

  timer:sleep(100),
  Events = instrument_flight_recorder:get_trace(TraceIdBin),
  ct:pal("Events (should not contain tracer bootstrap): ~p", [Events]),

  %% Verify we actually captured some events (sanity check)
  true = length(Events) > 0,

  %% Verify no tracer bootstrap messages in trace
  %% Pattern: {'receive', Pid, {Ref, {tracer, ...}}}
  TracerMsgs = [E || {_, E} <- Events,
                     is_tuple(E),
                     tuple_size(E) >= 3,
                     element(1, E) =:= 'receive',
                     is_tuple(element(3, E)),
                     tuple_size(element(3, E)) =:= 2,
                     is_tuple(element(2, element(3, E))),
                     tuple_size(element(2, element(3, E))) >= 1,
                     element(1, element(2, element(3, E))) =:= tracer],
  ct:pal("Tracer bootstrap messages found (should be empty): ~p", [TracerMsgs]),
  [] = TracerMsgs,
  ok.
