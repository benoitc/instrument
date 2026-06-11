%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Test helpers for validating instrumentation in EUnit and Common Test.
%%
%% This module provides collector exporters and assertion helpers for testing
%% spans, metrics, and logs in your instrumented code.
%%
%% == Quick Start ==
%% ```
%% my_test() ->
%%     instrument_test:setup(),
%%     try
%%         %% Your instrumented code
%%         instrument_tracer:with_span(<<"my_op">>, fun() ->
%%             do_work()
%%         end),
%%
%%         %% Assert span was created
%%         instrument_test:assert_span_exists(<<"my_op">>)
%%     after
%%         instrument_test:cleanup()
%%     end.
%% '''
%%
%% == Common Test Setup ==
%% ```
%% init_per_testcase(_TestCase, Config) ->
%%     instrument_test:setup(),
%%     Config.
%%
%% end_per_testcase(_TestCase, _Config) ->
%%     instrument_test:cleanup(),
%%     ok.
%% '''
-module(instrument_test).
-author("benoitc").

%% Setup/Cleanup
-export([
    setup/0,
    cleanup/0,
    reset/0
]).

%% Span Collection
-export([
    start_span_collector/0,
    stop_span_collector/0,
    get_spans/0,
    get_span/1,
    clear_spans/0,
    wait_for_spans/2
]).

%% Span Assertions
-export([
    assert_span_exists/1,
    assert_span/2,
    assert_span_attribute/3,
    assert_span_event/2,
    assert_span_status/2,
    assert_parent_child/2,
    assert_no_span/1
]).

%% Metrics Collection
-export([
    start_metrics_collector/0,
    stop_metrics_collector/0,
    get_metrics/0,
    collect_metrics/0,
    clear_metrics/0
]).

%% Metrics Assertions
-export([
    assert_counter/2,
    assert_counter/3,
    assert_gauge/2,
    assert_gauge/3,
    assert_histogram_count/2,
    assert_histogram_sum/2
]).

%% Log Collection
-export([
    start_log_collector/0,
    stop_log_collector/0,
    get_logs/0,
    clear_logs/0,
    wait_for_logs/2
]).

%% Log Assertions
-export([
    assert_log_exists/1,
    assert_log/2,
    assert_log_trace_context/1
]).

%% Test utilities
-export([
    add_test_log/1
]).

-include("instrument_otel.hrl").

-define(SPAN_TAB, instrument_test_spans).
-define(METRICS_TAB, instrument_test_metrics).
-define(LOG_TAB, instrument_test_logs).
-define(EXPORTER_KEY, instrument_test_span_exporter).
-define(LOG_EXPORTER_KEY, instrument_test_log_exporter).

%% ============================================================================
%% Setup/Cleanup
%% ============================================================================

%% @doc Sets up the test environment.
%% Starts the instrument application and all collectors.
-spec setup() -> ok.
setup() ->
    _ = application:ensure_all_started(instrument),
    _ = start_span_collector(),
    _ = start_metrics_collector(),
    _ = start_log_collector(),
    ok.

%% @doc Cleans up the test environment.
%% Stops collectors and clears all state.
-spec cleanup() -> ok.
cleanup() ->
    _ = stop_span_collector(),
    _ = stop_metrics_collector(),
    _ = stop_log_collector(),
    %% Clean up instrument state
    _ = instrument_metric:unregister_all(),
    _ = instrument_meter:unregister_all_instruments(),
    %% Clean up context
    erlang:erase('$instrument_context'),
    ok.

%% @doc Resets collectors between test cases without full cleanup.
%% Use this when you want to keep the application running but clear collected data.
%% Also ensures all collector tables exist.
-spec reset() -> ok.
reset() ->
    %% Ensure tables exist (they may have been lost if test process died)
    ensure_span_table(),
    ensure_metrics_table(),
    ensure_log_table(),
    %% Clear the tables
    clear_spans(),
    clear_metrics(),
    clear_logs(),
    %% Clean up context
    erlang:erase('$instrument_context'),
    ok.

ensure_span_table() ->
    case ets:info(?SPAN_TAB) of
        undefined ->
            _ = ets:new(?SPAN_TAB, [public, bag, named_table]);
        _ ->
            ok
    end.

ensure_metrics_table() ->
    case ets:info(?METRICS_TAB) of
        undefined ->
            _ = ets:new(?METRICS_TAB, [public, set, named_table]);
        _ ->
            ok
    end.

ensure_log_table() ->
    case ets:info(?LOG_TAB) of
        undefined ->
            _ = ets:new(?LOG_TAB, [public, bag, named_table]);
        _ ->
            ok
    end.

%% ============================================================================
%% Span Collection
%% ============================================================================

%% @doc Starts the span collector.
%% Registers an ETS-based exporter that captures all completed spans.
-spec start_span_collector() -> ok.
start_span_collector() ->
    %% First unregister any existing exporter
    case persistent_term:get(?EXPORTER_KEY, undefined) of
        undefined -> ok;
        OldExporter ->
            instrument_tracer:unregister_exporter(OldExporter)
    end,
    %% Create or clear the ETS table
    case ets:info(?SPAN_TAB) of
        undefined ->
            _ = ets:new(?SPAN_TAB, [public, bag, named_table]);
        _ ->
            ets:delete_all_objects(?SPAN_TAB)
    end,
    %% Create and register new exporter
    Exporter = fun(Span) ->
        case ets:info(?SPAN_TAB) of
            undefined -> ok;
            _ -> ets:insert(?SPAN_TAB, {span, Span})
        end
    end,
    persistent_term:put(?EXPORTER_KEY, Exporter),
    instrument_tracer:register_exporter(Exporter),
    ok.

%% @doc Stops the span collector.
-spec stop_span_collector() -> ok.
stop_span_collector() ->
    case persistent_term:get(?EXPORTER_KEY, undefined) of
        undefined -> ok;
        Exporter ->
            instrument_tracer:unregister_exporter(Exporter),
            persistent_term:erase(?EXPORTER_KEY)
    end,
    case ets:info(?SPAN_TAB) of
        undefined -> ok;
        _ -> ets:delete(?SPAN_TAB)
    end,
    ok.

%% @doc Returns all captured spans.
-spec get_spans() -> [#span{}].
get_spans() ->
    case ets:info(?SPAN_TAB) of
        undefined -> [];
        _ -> [Span || {span, Span} <- ets:tab2list(?SPAN_TAB)]
    end.

%% @doc Returns a span by name.
-spec get_span(binary()) -> {ok, #span{}} | {error, not_found}.
get_span(Name) when is_binary(Name) ->
    case [S || S <- get_spans(), S#span.name =:= Name] of
        [Span | _] -> {ok, Span};
        [] -> {error, not_found}
    end;
get_span(Name) when is_atom(Name) ->
    get_span(atom_to_binary(Name, utf8)).

%% @doc Clears all captured spans.
-spec clear_spans() -> ok.
clear_spans() ->
    case ets:info(?SPAN_TAB) of
        undefined -> ok;
        _ -> ets:delete_all_objects(?SPAN_TAB)
    end,
    ok.

%% @doc Waits for a specific number of spans with timeout.
-spec wait_for_spans(pos_integer(), pos_integer()) -> ok | {error, timeout}.
wait_for_spans(Count, Timeout) when Count > 0, Timeout > 0 ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_for_spans_loop(Count, Deadline).

wait_for_spans_loop(Count, Deadline) ->
    case length(get_spans()) >= Count of
        true -> ok;
        false ->
            Now = erlang:monotonic_time(millisecond),
            case Now >= Deadline of
                true -> {error, timeout};
                false ->
                    timer:sleep(10),
                    wait_for_spans_loop(Count, Deadline)
            end
    end.

%% ============================================================================
%% Span Assertions
%% ============================================================================

%% @doc Asserts that a span with the given name exists.
-spec assert_span_exists(binary() | atom()) -> ok.
assert_span_exists(Name) when is_atom(Name) ->
    assert_span_exists(atom_to_binary(Name, utf8));
assert_span_exists(Name) when is_binary(Name) ->
    case get_span(Name) of
        {ok, _} -> ok;
        {error, not_found} ->
            SpanNames = [S#span.name || S <- get_spans()],
            error({assertion_failed, {span_not_found, Name, SpanNames}})
    end.

%% @doc Asserts that no span with the given name exists.
-spec assert_no_span(binary() | atom()) -> ok.
assert_no_span(Name) when is_atom(Name) ->
    assert_no_span(atom_to_binary(Name, utf8));
assert_no_span(Name) when is_binary(Name) ->
    case get_span(Name) of
        {error, not_found} -> ok;
        {ok, Span} ->
            error({assertion_failed, {unexpected_span, Name, Span}})
    end.

%% @doc Asserts a span with expected properties.
%% Expected can contain: attributes, status, kind, parent
-spec assert_span(binary() | atom(), map()) -> ok.
assert_span(Name, Expected) when is_atom(Name) ->
    assert_span(atom_to_binary(Name, utf8), Expected);
assert_span(Name, Expected) when is_binary(Name), is_map(Expected) ->
    case get_span(Name) of
        {error, not_found} ->
            SpanNames = [S#span.name || S <- get_spans()],
            error({assertion_failed, {span_not_found, Name, SpanNames}});
        {ok, Span} ->
            maps:foreach(fun(Key, ExpVal) ->
                assert_span_property(Name, Span, Key, ExpVal)
            end, Expected),
            ok
    end.

assert_span_property(Name, _Span, attributes, ExpAttrs) when is_map(ExpAttrs) ->
    maps:foreach(fun(K, V) ->
        assert_span_attribute(Name, K, V)
    end, ExpAttrs);
assert_span_property(_Name, Span, status, ExpStatus) ->
    case Span#span.status of
        ExpStatus -> ok;
        Actual ->
            error({assertion_failed, {status_mismatch, ExpStatus, Actual}})
    end;
assert_span_property(_Name, Span, kind, ExpKind) ->
    case Span#span.kind of
        ExpKind -> ok;
        Actual ->
            error({assertion_failed, {kind_mismatch, ExpKind, Actual}})
    end;
assert_span_property(Name, _Span, parent, ExpParent) ->
    assert_parent_child(ExpParent, Name);
assert_span_property(_Name, _Span, Key, _) ->
    error({assertion_failed, {unknown_property, Key}}).

%% @doc Asserts a specific attribute value on a span.
-spec assert_span_attribute(binary() | atom(), term(), term()) -> ok.
assert_span_attribute(SpanName, Key, ExpectedValue) when is_atom(SpanName) ->
    assert_span_attribute(atom_to_binary(SpanName, utf8), Key, ExpectedValue);
assert_span_attribute(SpanName, Key, ExpectedValue) when is_binary(SpanName) ->
    case get_span(SpanName) of
        {error, not_found} ->
            error({assertion_failed, {span_not_found, SpanName}});
        {ok, Span} ->
            Actual = maps:get(Key, Span#span.attributes, undefined),
            case Actual of
                ExpectedValue -> ok;
                _ ->
                    error({assertion_failed,
                           {attribute_mismatch, SpanName, Key, ExpectedValue, Actual}})
            end
    end.

%% @doc Asserts that a span has an event with the given name.
-spec assert_span_event(binary() | atom(), binary()) -> ok.
assert_span_event(SpanName, EventName) when is_atom(SpanName) ->
    assert_span_event(atom_to_binary(SpanName, utf8), EventName);
assert_span_event(SpanName, EventName) when is_binary(SpanName), is_binary(EventName) ->
    case get_span(SpanName) of
        {error, not_found} ->
            error({assertion_failed, {span_not_found, SpanName}});
        {ok, Span} ->
            Events = [E#span_event.name || E <- Span#span.events],
            case lists:member(EventName, Events) of
                true -> ok;
                false ->
                    error({assertion_failed, {event_not_found, SpanName, EventName, Events}})
            end
    end.

%% @doc Asserts the status of a span.
-spec assert_span_status(binary() | atom(), ok | unset | {error, binary()}) -> ok.
assert_span_status(SpanName, ExpectedStatus) when is_atom(SpanName) ->
    assert_span_status(atom_to_binary(SpanName, utf8), ExpectedStatus);
assert_span_status(SpanName, ExpectedStatus) when is_binary(SpanName) ->
    case get_span(SpanName) of
        {error, not_found} ->
            error({assertion_failed, {span_not_found, SpanName}});
        {ok, Span} ->
            case match_status(Span#span.status, ExpectedStatus) of
                true -> ok;
                false ->
                    error({assertion_failed,
                           {status_mismatch, SpanName, ExpectedStatus, Span#span.status}})
            end
    end.

match_status(Status, Status) -> true;
match_status({error, _}, error) -> true;
match_status(_, _) -> false.

%% @doc Asserts that ParentName is the parent of ChildName.
-spec assert_parent_child(binary() | atom(), binary() | atom()) -> ok.
assert_parent_child(ParentName, ChildName) when is_atom(ParentName) ->
    assert_parent_child(atom_to_binary(ParentName, utf8), ChildName);
assert_parent_child(ParentName, ChildName) when is_atom(ChildName) ->
    assert_parent_child(ParentName, atom_to_binary(ChildName, utf8));
assert_parent_child(ParentName, ChildName) when is_binary(ParentName), is_binary(ChildName) ->
    case {get_span(ParentName), get_span(ChildName)} of
        {{error, not_found}, _} ->
            error({assertion_failed, {parent_span_not_found, ParentName}});
        {_, {error, not_found}} ->
            error({assertion_failed, {child_span_not_found, ChildName}});
        {{ok, Parent}, {ok, Child}} ->
            ParentSpanId = Parent#span.ctx#span_ctx.span_id,
            ChildParentCtx = Child#span.parent_ctx,
            case ChildParentCtx of
                #span_ctx{span_id = ParentSpanId} -> ok;
                _ ->
                    error({assertion_failed,
                           {not_parent_child, ParentName, ChildName,
                            Parent#span.ctx, ChildParentCtx}})
            end
    end.

%% ============================================================================
%% Metrics Collection
%% ============================================================================

%% @doc Starts the metrics collector.
-spec start_metrics_collector() -> ok.
start_metrics_collector() ->
    case ets:info(?METRICS_TAB) of
        undefined ->
            _ = ets:new(?METRICS_TAB, [public, set, named_table]);
        _ ->
            ets:delete_all_objects(?METRICS_TAB)
    end,
    ok.

%% @doc Stops the metrics collector.
-spec stop_metrics_collector() -> ok.
stop_metrics_collector() ->
    case ets:info(?METRICS_TAB) of
        undefined -> ok;
        _ -> ets:delete(?METRICS_TAB)
    end,
    ok.

%% @doc Returns all collected metrics.
-spec get_metrics() -> [map()].
get_metrics() ->
    case ets:info(?METRICS_TAB) of
        undefined -> [];
        _ ->
            case ets:lookup(?METRICS_TAB, metrics) of
                [{metrics, Metrics}] -> Metrics;
                [] -> []
            end
    end.

%% @doc Triggers metrics collection and returns the results.
-spec collect_metrics() -> [map()].
collect_metrics() ->
    Metrics = instrument_metrics_exporter:collect(),
    case ets:info(?METRICS_TAB) of
        undefined -> ok;
        _ -> ets:insert(?METRICS_TAB, {metrics, Metrics})
    end,
    Metrics.

%% @doc Clears collected metrics.
-spec clear_metrics() -> ok.
clear_metrics() ->
    case ets:info(?METRICS_TAB) of
        undefined -> ok;
        _ -> ets:delete_all_objects(?METRICS_TAB)
    end,
    ok.

%% ============================================================================
%% Metrics Assertions
%% ============================================================================

%% @doc Asserts a counter has the expected value.
-spec assert_counter(binary() | atom(), number()) -> ok.
assert_counter(Name, ExpectedValue) ->
    assert_counter(Name, ExpectedValue, #{}).

%% @doc Asserts a counter has the expected value with specific attributes.
-spec assert_counter(binary() | atom(), number(), map()) -> ok.
assert_counter(Name, ExpectedValue, Attrs) when is_atom(Name) ->
    assert_counter(atom_to_binary(Name, utf8), ExpectedValue, Attrs);
assert_counter(Name, ExpectedValue, Attrs) when is_binary(Name) ->
    Metrics = collect_metrics(),
    assert_metric_value(Name, counter, ExpectedValue, Attrs, Metrics).

%% @doc Asserts a gauge has the expected value.
-spec assert_gauge(binary() | atom(), number()) -> ok.
assert_gauge(Name, ExpectedValue) ->
    assert_gauge(Name, ExpectedValue, #{}).

%% @doc Asserts a gauge has the expected value with specific attributes.
-spec assert_gauge(binary() | atom(), number(), map()) -> ok.
assert_gauge(Name, ExpectedValue, Attrs) when is_atom(Name) ->
    assert_gauge(atom_to_binary(Name, utf8), ExpectedValue, Attrs);
assert_gauge(Name, ExpectedValue, Attrs) when is_binary(Name) ->
    Metrics = collect_metrics(),
    assert_metric_value(Name, gauge, ExpectedValue, Attrs, Metrics).

%% @doc Asserts a histogram has the expected observation count.
-spec assert_histogram_count(binary() | atom(), non_neg_integer()) -> ok.
assert_histogram_count(Name, ExpectedCount) when is_atom(Name) ->
    assert_histogram_count(atom_to_binary(Name, utf8), ExpectedCount);
assert_histogram_count(Name, ExpectedCount) when is_binary(Name) ->
    Metrics = collect_metrics(),
    case find_metric(Name, histogram, Metrics) of
        {ok, Metric} ->
            DataPoints = maps:get(data_points, Metric, []),
            case DataPoints of
                [#{value := #{count := Count}} | _] ->
                    %% Handle both integer and float comparison
                    case trunc(Count) =:= ExpectedCount of
                        true -> ok;
                        false ->
                            error({assertion_failed, {histogram_count_mismatch, Name, ExpectedCount, Count}})
                    end;
                _ ->
                    error({assertion_failed, {histogram_no_data, Name}})
            end;
        {error, not_found} ->
            MetricNames = [maps:get(name, M) || M <- Metrics],
            error({assertion_failed, {metric_not_found, Name, MetricNames}})
    end.

%% @doc Asserts a histogram has the expected sum.
-spec assert_histogram_sum(binary() | atom(), number()) -> ok.
assert_histogram_sum(Name, ExpectedSum) when is_atom(Name) ->
    assert_histogram_sum(atom_to_binary(Name, utf8), ExpectedSum);
assert_histogram_sum(Name, ExpectedSum) when is_binary(Name) ->
    Metrics = collect_metrics(),
    case find_metric(Name, histogram, Metrics) of
        {ok, Metric} ->
            DataPoints = maps:get(data_points, Metric, []),
            case DataPoints of
                [#{value := #{sum := Sum}} | _] ->
                    case abs(Sum - ExpectedSum) < 0.001 of
                        true -> ok;
                        false ->
                            error({assertion_failed, {histogram_sum_mismatch, Name, ExpectedSum, Sum}})
                    end;
                _ ->
                    error({assertion_failed, {histogram_no_data, Name}})
            end;
        {error, not_found} ->
            MetricNames = [maps:get(name, M) || M <- Metrics],
            error({assertion_failed, {metric_not_found, Name, MetricNames}})
    end.

assert_metric_value(Name, Type, ExpectedValue, Attrs, Metrics) ->
    case find_metric(Name, Type, Metrics) of
        {ok, Metric} ->
            DataPoints = maps:get(data_points, Metric, []),
            case find_data_point(Attrs, DataPoints) of
                {ok, #{value := Value}} ->
                    case abs(Value - ExpectedValue) < 0.001 of
                        true -> ok;
                        false ->
                            error({assertion_failed, {value_mismatch, Name, ExpectedValue, Value}})
                    end;
                {error, not_found} ->
                    error({assertion_failed, {data_point_not_found, Name, Attrs, DataPoints}})
            end;
        {error, not_found} ->
            MetricNames = [maps:get(name, M) || M <- Metrics],
            error({assertion_failed, {metric_not_found, Name, MetricNames}})
    end.

find_metric(Name, Type, Metrics) ->
    %% Try exact match first, then with otel prefix
    Names = [Name, <<"{otel,", Name/binary, "}">>],
    find_metric_by_names(Names, Type, Metrics).

find_metric_by_names([], _Type, _Metrics) ->
    {error, not_found};
find_metric_by_names([Name | Rest], Type, Metrics) ->
    case [M || M <- Metrics,
               name_matches(maps:get(name, M, undefined), Name),
               maps:get(type, M) =:= Type] of
        [Metric | _] -> {ok, Metric};
        [] -> find_metric_by_names(Rest, Type, Metrics)
    end.

name_matches(Name, Name) -> true;
name_matches({_, Name}, Name) -> true;
name_matches({otel, Name}, SearchName) when is_binary(Name), is_binary(SearchName) ->
  Name =:= SearchName;
name_matches(_, _) -> false.

find_data_point(ExpectedAttrs, DataPoints) when map_size(ExpectedAttrs) =:= 0 ->
    case DataPoints of
        [DP | _] -> {ok, DP};
        [] -> {error, not_found}
    end;
find_data_point(ExpectedAttrs, DataPoints) ->
    case [DP || DP <- DataPoints,
                maps_match(ExpectedAttrs, maps:get(attributes, DP, #{}))] of
        [DP | _] -> {ok, DP};
        [] -> {error, not_found}
    end.

maps_match(Expected, Actual) ->
    maps:fold(fun(K, V, Acc) ->
        Acc andalso maps:get(K, Actual, undefined) =:= V
    end, true, Expected).

%% ============================================================================
%% Log Collection
%% ============================================================================

%% @doc Starts the log collector.
-spec start_log_collector() -> ok.
start_log_collector() ->
    case ets:info(?LOG_TAB) of
        undefined ->
            _ = ets:new(?LOG_TAB, [public, bag, named_table]);
        _ ->
            ets:delete_all_objects(?LOG_TAB)
    end,
    %% Register a log exporter module
    Exporter = #{
        module => instrument_test_log_exporter,
        config => #{table => ?LOG_TAB}
    },
    persistent_term:put(?LOG_EXPORTER_KEY, Exporter),
    try instrument_log_exporter:register(Exporter) catch _:_ -> ok end,
    ok.

%% @doc Stops the log collector.
-spec stop_log_collector() -> ok.
stop_log_collector() ->
    case persistent_term:get(?LOG_EXPORTER_KEY, undefined) of
        undefined -> ok;
        #{module := Mod} ->
            try instrument_log_exporter:unregister(Mod) catch _:_ -> ok end,
            persistent_term:erase(?LOG_EXPORTER_KEY)
    end,
    case ets:info(?LOG_TAB) of
        undefined -> ok;
        _ -> ets:delete(?LOG_TAB)
    end,
    ok.

%% @doc Returns all captured logs.
-spec get_logs() -> [#log_record{}].
get_logs() ->
    case ets:info(?LOG_TAB) of
        undefined -> [];
        _ -> [Log || {log, Log} <- ets:tab2list(?LOG_TAB)]
    end.

%% @doc Clears all captured logs.
-spec clear_logs() -> ok.
clear_logs() ->
    case ets:info(?LOG_TAB) of
        undefined -> ok;
        _ -> ets:delete_all_objects(?LOG_TAB)
    end,
    ok.

%% @doc Waits for a specific number of logs with timeout.
-spec wait_for_logs(pos_integer(), pos_integer()) -> ok | {error, timeout}.
wait_for_logs(Count, Timeout) when Count > 0, Timeout > 0 ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_for_logs_loop(Count, Deadline).

wait_for_logs_loop(Count, Deadline) ->
    case length(get_logs()) >= Count of
        true -> ok;
        false ->
            Now = erlang:monotonic_time(millisecond),
            case Now >= Deadline of
                true -> {error, timeout};
                false ->
                    timer:sleep(10),
                    wait_for_logs_loop(Count, Deadline)
            end
    end.

%% ============================================================================
%% Log Assertions
%% ============================================================================

%% @doc Asserts that a log with the given body pattern exists.
-spec assert_log_exists(term()) -> ok.
assert_log_exists(BodyPattern) ->
    Logs = get_logs(),
    case find_log_by_body(BodyPattern, Logs) of
        {ok, _} -> ok;
        {error, not_found} ->
            Bodies = [L#log_record.body || L <- Logs],
            error({assertion_failed, {log_not_found, BodyPattern, Bodies}})
    end.

%% @doc Asserts a log record with expected properties.
%% Expected can contain: body, severity_text, severity_number, attributes
-spec assert_log(term(), map()) -> ok.
assert_log(BodyPattern, Expected) when is_map(Expected) ->
    Logs = get_logs(),
    case find_log_by_body(BodyPattern, Logs) of
        {ok, Log} ->
            maps:foreach(fun(Key, ExpVal) ->
                assert_log_property(Log, Key, ExpVal)
            end, Expected),
            ok;
        {error, not_found} ->
            Bodies = [L#log_record.body || L <- Logs],
            error({assertion_failed, {log_not_found, BodyPattern, Bodies}})
    end.

assert_log_property(Log, severity_text, ExpVal) ->
    case Log#log_record.severity_text of
        ExpVal -> ok;
        Actual -> error({assertion_failed, {severity_text_mismatch, ExpVal, Actual}})
    end;
assert_log_property(Log, severity_number, ExpVal) ->
    case Log#log_record.severity_number of
        ExpVal -> ok;
        Actual -> error({assertion_failed, {severity_number_mismatch, ExpVal, Actual}})
    end;
assert_log_property(Log, attributes, ExpAttrs) when is_map(ExpAttrs) ->
    ActualAttrs = Log#log_record.attributes,
    maps:foreach(fun(K, V) ->
        case maps:get(K, ActualAttrs, undefined) of
            V -> ok;
            Actual -> error({assertion_failed, {log_attribute_mismatch, K, V, Actual}})
        end
    end, ExpAttrs);
assert_log_property(Log, trace_id, ExpVal) ->
    case Log#log_record.trace_id of
        ExpVal -> ok;
        Actual -> error({assertion_failed, {trace_id_mismatch, ExpVal, Actual}})
    end;
assert_log_property(Log, span_id, ExpVal) ->
    case Log#log_record.span_id of
        ExpVal -> ok;
        Actual -> error({assertion_failed, {span_id_mismatch, ExpVal, Actual}})
    end;
assert_log_property(_Log, Key, _) ->
    error({assertion_failed, {unknown_log_property, Key}}).

%% @doc Asserts that a log has trace context (trace_id and span_id).
-spec assert_log_trace_context(term()) -> ok.
assert_log_trace_context(BodyPattern) ->
    Logs = get_logs(),
    case find_log_by_body(BodyPattern, Logs) of
        {ok, Log} ->
            case {Log#log_record.trace_id, Log#log_record.span_id} of
                {undefined, _} ->
                    error({assertion_failed, {missing_trace_id, BodyPattern}});
                {_, undefined} ->
                    error({assertion_failed, {missing_span_id, BodyPattern}});
                {TraceId, SpanId} when is_binary(TraceId), is_binary(SpanId) ->
                    ok
            end;
        {error, not_found} ->
            Bodies = [L#log_record.body || L <- Logs],
            error({assertion_failed, {log_not_found, BodyPattern, Bodies}})
    end.

find_log_by_body(Pattern, Logs) when is_binary(Pattern) ->
    case [L || L <- Logs, log_body_matches(Pattern, L#log_record.body)] of
        [Log | _] -> {ok, Log};
        [] -> {error, not_found}
    end;
find_log_by_body(Pattern, Logs) ->
    case [L || L <- Logs, L#log_record.body =:= Pattern] of
        [Log | _] -> {ok, Log};
        [] -> {error, not_found}
    end.

log_body_matches(Pattern, Body) when is_binary(Pattern), is_binary(Body) ->
    binary:match(Body, Pattern) =/= nomatch;
log_body_matches(Pattern, Body) ->
    Pattern =:= Body.

%% ============================================================================
%% Test Utilities
%% ============================================================================

%% @doc Adds a log record directly for testing purposes.
%% Ensures the log table exists before inserting.
-spec add_test_log(#log_record{}) -> ok.
add_test_log(LogRecord) ->
    %% Ensure table exists
    case ets:info(?LOG_TAB) of
        undefined ->
            _ = ets:new(?LOG_TAB, [public, bag, named_table]);
        _ ->
            ok
    end,
    ets:insert(?LOG_TAB, {log, LogRecord}),
    ok.
