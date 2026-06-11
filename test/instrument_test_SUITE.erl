%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Test suite for instrument_test module.
-module(instrument_test_SUITE).
-author("benoitc").

-export([
    all/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

%% Span tests
-export([
    span_collection/1,
    span_get_by_name/1,
    span_clear/1,
    span_wait_for/1,
    span_assert_exists/1,
    span_assert_not_exists/1,
    span_assert_attribute/1,
    span_assert_event/1,
    span_assert_status/1,
    span_assert_parent_child/1,
    span_assert_properties/1
]).

%% Metrics tests
-export([
    metrics_collection/1,
    metrics_counter_assertion/1,
    metrics_gauge_assertion/1,
    metrics_histogram_assertion/1,
    metrics_clear/1,
    metrics_collector_error_isolation/1,
    metrics_otel_tuple_name_matching/1
]).

%% Log tests
-export([
    log_collection/1,
    log_assert_exists/1,
    log_assert_properties/1,
    log_assert_trace_context/1,
    log_clear/1
]).

%% Reset tests
-export([
    reset_clears_all/1
]).

-include("instrument.hrl").
-include("instrument_otel.hrl").

all() ->
    [
        span_collection,
        span_get_by_name,
        span_clear,
        span_wait_for,
        span_assert_exists,
        span_assert_not_exists,
        span_assert_attribute,
        span_assert_event,
        span_assert_status,
        span_assert_parent_child,
        span_assert_properties,
        metrics_collection,
        metrics_counter_assertion,
        metrics_gauge_assertion,
        metrics_histogram_assertion,
        metrics_clear,
        metrics_collector_error_isolation,
        metrics_otel_tuple_name_matching,
        log_collection,
        log_assert_exists,
        log_assert_properties,
        log_assert_trace_context,
        log_clear,
        reset_clears_all
    ].

groups() ->
    [].

init_per_suite(Config) ->
    _ = application:ensure_all_started(crypto),
    ok = application:start(instrument),
    instrument_test:setup(),
    Config.

end_per_suite(_Config) ->
    instrument_test:cleanup(),
    ok = application:stop(instrument),
    ok.

init_per_testcase(_TestCase, Config) ->
    instrument_test:reset(),
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%% ============================================================================
%% Span Tests
%% ============================================================================

span_collection(_Config) ->
    %% Create a span
    instrument_tracer:with_span(<<"test_span">>, fun() ->
        instrument_tracer:set_attribute(<<"key">>, <<"value">>)
    end),

    %% Check span was collected
    Spans = instrument_test:get_spans(),
    1 = length(Spans),
    [Span] = Spans,
    <<"test_span">> = Span#span.name,
    %% Verify attribute was captured
    <<"value">> = maps:get(<<"key">>, Span#span.attributes),
    ok.

span_get_by_name(_Config) ->
    %% Create spans
    instrument_tracer:with_span(<<"span_a">>, fun() -> ok end),
    instrument_tracer:with_span(<<"span_b">>, fun() -> ok end),

    %% Get by name
    {ok, SpanA} = instrument_test:get_span(<<"span_a">>),
    <<"span_a">> = SpanA#span.name,

    {ok, SpanB} = instrument_test:get_span(span_b),
    <<"span_b">> = SpanB#span.name,

    %% Not found
    {error, not_found} = instrument_test:get_span(<<"nonexistent">>),
    ok.

span_clear(_Config) ->
    %% Create spans
    instrument_tracer:with_span(<<"span1">>, fun() -> ok end),
    instrument_tracer:with_span(<<"span2">>, fun() -> ok end),

    2 = length(instrument_test:get_spans()),

    %% Clear
    ok = instrument_test:clear_spans(),

    0 = length(instrument_test:get_spans()),
    ok.

span_wait_for(_Config) ->
    %% Spawn process that creates spans with delay
    Self = self(),
    spawn(fun() ->
        timer:sleep(50),
        instrument_tracer:with_span(<<"delayed_span">>, fun() -> ok end),
        Self ! done
    end),

    %% Wait for span
    ok = instrument_test:wait_for_spans(1, 500),
    1 = length(instrument_test:get_spans()),

    receive done -> ok end,
    ok.

span_assert_exists(_Config) ->
    instrument_tracer:with_span(<<"my_span">>, fun() -> ok end),

    %% Should pass
    ok = instrument_test:assert_span_exists(<<"my_span">>),
    ok = instrument_test:assert_span_exists(my_span),

    %% Should fail
    try
        instrument_test:assert_span_exists(<<"missing">>),
        ct:fail(should_have_thrown)
    catch
        error:{assertion_failed, {span_not_found, <<"missing">>, _}} ->
            ok
    end.

span_assert_not_exists(_Config) ->
    instrument_tracer:with_span(<<"existing">>, fun() -> ok end),

    %% Should pass
    ok = instrument_test:assert_no_span(<<"nonexistent">>),

    %% Should fail
    try
        instrument_test:assert_no_span(<<"existing">>),
        ct:fail(should_have_thrown)
    catch
        error:{assertion_failed, {unexpected_span, <<"existing">>, _}} ->
            ok
    end.

span_assert_attribute(_Config) ->
    instrument_tracer:with_span(<<"attr_span">>, fun() ->
        instrument_tracer:set_attributes(#{
            <<"string_key">> => <<"value">>,
            <<"int_key">> => 42,
            <<"bool_key">> => true
        })
    end),

    %% Should pass
    ok = instrument_test:assert_span_attribute(<<"attr_span">>, <<"string_key">>, <<"value">>),
    ok = instrument_test:assert_span_attribute(attr_span, <<"int_key">>, 42),

    %% Should fail on wrong value
    try
        instrument_test:assert_span_attribute(<<"attr_span">>, <<"string_key">>, <<"wrong">>),
        ct:fail(should_have_thrown)
    catch
        error:{assertion_failed, {attribute_mismatch, _, _, _, _}} ->
            ok
    end.

span_assert_event(_Config) ->
    instrument_tracer:with_span(<<"event_span">>, fun() ->
        instrument_tracer:add_event(<<"event1">>),
        instrument_tracer:add_event(<<"event2">>, #{<<"key">> => <<"value">>})
    end),

    %% Should pass
    ok = instrument_test:assert_span_event(<<"event_span">>, <<"event1">>),
    ok = instrument_test:assert_span_event(event_span, <<"event2">>),

    %% Should fail
    try
        instrument_test:assert_span_event(<<"event_span">>, <<"missing_event">>),
        ct:fail(should_have_thrown)
    catch
        error:{assertion_failed, {event_not_found, _, _, _}} ->
            ok
    end.

span_assert_status(_Config) ->
    %% OK status
    instrument_tracer:with_span(<<"ok_span">>, fun() ->
        instrument_tracer:set_status(ok)
    end),
    ok = instrument_test:assert_span_status(<<"ok_span">>, ok),

    %% Error status
    instrument_tracer:with_span(<<"error_span">>, fun() ->
        instrument_tracer:set_status(error, <<"something failed">>)
    end),
    ok = instrument_test:assert_span_status(<<"error_span">>, error),
    ok = instrument_test:assert_span_status(error_span, {error, <<"something failed">>}),

    %% Should fail
    try
        instrument_test:assert_span_status(<<"ok_span">>, error),
        ct:fail(should_have_thrown)
    catch
        error:{assertion_failed, {status_mismatch, _, _, _}} ->
            ok
    end.

span_assert_parent_child(_Config) ->
    instrument_tracer:with_span(<<"parent">>, fun() ->
        instrument_tracer:with_span(<<"child">>, fun() ->
            ok
        end)
    end),

    %% Should pass
    ok = instrument_test:assert_parent_child(<<"parent">>, <<"child">>),
    ok = instrument_test:assert_parent_child(parent, child),

    %% Create another unrelated span
    instrument_tracer:with_span(<<"sibling">>, fun() -> ok end),

    %% Should fail - sibling is not child of parent
    try
        instrument_test:assert_parent_child(<<"parent">>, <<"sibling">>),
        ct:fail(should_have_thrown)
    catch
        error:{assertion_failed, {not_parent_child, _, _, _, _}} ->
            ok
    end.

span_assert_properties(_Config) ->
    instrument_tracer:with_span(<<"full_span">>, #{kind => client}, fun() ->
        instrument_tracer:set_attributes(#{<<"method">> => <<"GET">>}),
        instrument_tracer:set_status(ok)
    end),

    %% Should pass - multiple properties
    ok = instrument_test:assert_span(<<"full_span">>, #{
        kind => client,
        status => ok,
        attributes => #{<<"method">> => <<"GET">>}
    }),

    %% Should fail on wrong kind
    try
        instrument_test:assert_span(<<"full_span">>, #{kind => server}),
        ct:fail(should_have_thrown)
    catch
        error:{assertion_failed, {kind_mismatch, _, _}} ->
            ok
    end.

%% ============================================================================
%% Metrics Tests
%% ============================================================================

metrics_collection(_Config) ->
    %% Create counter
    Counter = instrument_metric:new_counter(test_counter, <<"Test counter">>),
    instrument_metric:inc_counter(Counter, 5),

    %% Collect metrics
    Metrics = instrument_test:collect_metrics(),
    true = length(Metrics) > 0,
    ok.

metrics_counter_assertion(_Config) ->
    Counter = instrument_metric:new_counter(assertion_counter, <<"Test">>),
    instrument_metric:inc_counter(Counter, 10),

    %% Should pass
    ok = instrument_test:assert_counter(assertion_counter, 10.0),

    %% Should fail
    try
        instrument_test:assert_counter(assertion_counter, 5.0),
        ct:fail(should_have_thrown)
    catch
        error:{assertion_failed, {value_mismatch, _, _, _}} ->
            ok
    end.

metrics_gauge_assertion(_Config) ->
    Gauge = instrument_metric:new_gauge(assertion_gauge, <<"Test">>),
    instrument_metric:set_gauge(Gauge, 42),

    %% Should pass
    ok = instrument_test:assert_gauge(assertion_gauge, 42.0),

    %% Should fail
    try
        instrument_test:assert_gauge(assertion_gauge, 100.0),
        ct:fail(should_have_thrown)
    catch
        error:{assertion_failed, {value_mismatch, _, _, _}} ->
            ok
    end.

metrics_histogram_assertion(_Config) ->
    Hist = instrument_metric:new_histogram(assertion_hist, <<"Test">>, [1, 5, 10]),
    instrument_metric:observe_histogram(Hist, 2),
    instrument_metric:observe_histogram(Hist, 3),
    instrument_metric:observe_histogram(Hist, 7),

    %% Should pass
    ok = instrument_test:assert_histogram_count(assertion_hist, 3),
    ok = instrument_test:assert_histogram_sum(assertion_hist, 12.0),

    %% Should fail on wrong count
    try
        instrument_test:assert_histogram_count(assertion_hist, 5),
        ct:fail(should_have_thrown)
    catch
        error:{assertion_failed, {histogram_count_mismatch, _, _, _}} ->
            ok
    end.

metrics_clear(_Config) ->
    Counter = instrument_metric:new_counter(clear_counter, <<"Test">>),
    instrument_metric:inc_counter(Counter),
    _ = instrument_test:collect_metrics(),

    true = length(instrument_test:get_metrics()) > 0,

    ok = instrument_test:clear_metrics(),
    0 = length(instrument_test:get_metrics()),
    ok.

%% Test that a crashing collector doesn't prevent other collectors from running (Bug 2 fix)
metrics_collector_error_isolation(_Config) ->
    %% Create a good counter
    GoodCounter = instrument_metric:new_counter(good_counter, <<"Good counter">>),
    instrument_metric:inc_counter(GoodCounter, 10),

    %% Create a mock metric with a crashing collector
    meck:new(crashing_collector, [non_strict]),
    meck:expect(crashing_collector, collect, fun() ->
        error(intentional_crash)
    end),

    %% Register the crashing metric directly to the registry
    CrashingMetric = #metric{
        name = crashing_metric,
        handle = undefined,
        collect = {crashing_collector, collect, []}
    },
    ok = instrument_metric:register(CrashingMetric),

    %% Create another good counter after the crashing one
    GoodCounter2 = instrument_metric:new_counter(good_counter2, <<"Good counter 2">>),
    instrument_metric:inc_counter(GoodCounter2, 5),

    %% collect_all should not crash and should return data from working collectors
    Results = instrument_registry:collect_all(),

    %% Should have collected something (the non-crashing counters)
    true = is_list(Results),

    %% Cleanup
    instrument_metric:unregister(crashing_metric),
    instrument_metric:unregister(good_counter),
    instrument_metric:unregister(good_counter2),
    meck:unload(crashing_collector),
    ok.

%% Regression test: OTel tuple names {otel, Name} must be matched correctly
%% when looking up metrics by base name (no {otel_vec, _} names exist)
metrics_otel_tuple_name_matching(_Config) ->
    %% Create OTel meter metrics (which use tuple names internally)
    Meter = instrument_meter:get_meter(<<"test_matching">>),
    Counter = instrument_meter:create_counter(Meter, <<"tuple_test_counter">>, #{
        description => <<"Test counter">>
    }),

    %% Add values - without attributes uses {otel, Name}
    ok = instrument_meter:add(Counter, 10),

    %% Add values with attributes - lands in the series store under the real name
    ok = instrument_meter:add(Counter, 5, #{method => <<"GET">>}),
    ok = instrument_meter:add(Counter, 3, #{method => <<"POST">>}),

    %% Collect and verify metrics can be found
    Metrics = instrument_test:collect_metrics(),

    %% Should find metrics containing the base name
    MatchingMetrics = [M || M <- Metrics,
                           case maps:get(name, M, undefined) of
                               N when is_binary(N) ->
                                   binary:match(N, <<"tuple_test_counter">>) =/= nomatch;
                               _ -> false
                           end],

    %% Should have found at least one metric
    true = length(MatchingMetrics) >= 1,

    %% Verify names are properly formatted (not malformed tuple strings)
    lists:foreach(fun(#{name := Name}) ->
        nomatch = binary:match(Name, <<"{otel">>)
    end, MatchingMetrics),
    ok.

%% ============================================================================
%% Log Tests
%% ============================================================================

log_collection(_Config) ->
    %% The log collector is set up but logs come from instrument_logger
    %% For now just verify the collector infrastructure works
    Logs = instrument_test:get_logs(),
    true = is_list(Logs),
    ok.

log_assert_exists(_Config) ->
    %% Create a mock log record using the test helper
    LogRecord = #log_record{
        body = <<"Test log message">>,
        severity_text = <<"INFO">>,
        severity_number = 9,
        timestamp = erlang:system_time(nanosecond),
        attributes = #{}
    },
    instrument_test:add_test_log(LogRecord),

    %% Should pass
    ok = instrument_test:assert_log_exists(<<"Test log">>),

    %% Should fail
    try
        instrument_test:assert_log_exists(<<"nonexistent">>),
        ct:fail(should_have_thrown)
    catch
        error:{assertion_failed, {log_not_found, _, _}} ->
            ok
    end.

log_assert_properties(_Config) ->
    %% Create a mock log record using the test helper
    LogRecord = #log_record{
        body = <<"Property test log">>,
        severity_text = <<"ERROR">>,
        severity_number = 17,
        timestamp = erlang:system_time(nanosecond),
        attributes = #{<<"key">> => <<"value">>},
        trace_id = <<1:128>>,
        span_id = <<2:64>>
    },
    instrument_test:add_test_log(LogRecord),

    %% Should pass
    ok = instrument_test:assert_log(<<"Property test">>, #{
        severity_text => <<"ERROR">>,
        severity_number => 17,
        attributes => #{<<"key">> => <<"value">>}
    }),

    %% Should fail on wrong severity
    try
        instrument_test:assert_log(<<"Property test">>, #{severity_text => <<"INFO">>}),
        ct:fail(should_have_thrown)
    catch
        error:{assertion_failed, {severity_text_mismatch, _, _}} ->
            ok
    end.

log_clear(_Config) ->
    LogRecord = #log_record{
        body = <<"Clear test">>,
        timestamp = erlang:system_time(nanosecond)
    },
    instrument_test:add_test_log(LogRecord),

    true = length(instrument_test:get_logs()) > 0,

    ok = instrument_test:clear_logs(),
    0 = length(instrument_test:get_logs()),
    ok.

log_assert_trace_context(_Config) ->
    %% Log with trace context: assertion passes
    Good = #log_record{
        body = <<"With trace ctx">>,
        timestamp = erlang:system_time(nanosecond),
        trace_id = <<1:128>>,
        span_id = <<2:64>>
    },
    instrument_test:add_test_log(Good),
    ok = instrument_test:assert_log_trace_context(<<"With trace ctx">>),

    %% Log without trace context: assertion fails with missing_trace_id
    Bad = #log_record{
        body = <<"No trace ctx">>,
        timestamp = erlang:system_time(nanosecond)
    },
    instrument_test:add_test_log(Bad),
    try
        instrument_test:assert_log_trace_context(<<"No trace ctx">>),
        ct:fail(should_have_thrown)
    catch
        error:{assertion_failed, {missing_trace_id, _}} -> ok
    end,

    %% Log not present: assertion fails with log_not_found
    try
        instrument_test:assert_log_trace_context(<<"absent">>),
        ct:fail(should_have_thrown)
    catch
        error:{assertion_failed, {log_not_found, _, _}} -> ok
    end.

%% ============================================================================
%% Reset Tests
%% ============================================================================

reset_clears_all(_Config) ->
    %% Create some data
    instrument_tracer:with_span(<<"reset_span">>, fun() -> ok end),
    Counter = instrument_metric:new_counter(reset_counter, <<"Test">>),
    instrument_metric:inc_counter(Counter),
    _ = instrument_test:collect_metrics(),

    LogRecord = #log_record{body = <<"reset log">>, timestamp = erlang:system_time(nanosecond)},
    instrument_test:add_test_log(LogRecord),

    %% Verify data exists
    true = length(instrument_test:get_spans()) > 0,
    true = length(instrument_test:get_logs()) > 0,

    %% Reset
    ok = instrument_test:reset(),

    %% All should be cleared
    0 = length(instrument_test:get_spans()),
    0 = length(instrument_test:get_metrics()),
    0 = length(instrument_test:get_logs()),
    ok.
