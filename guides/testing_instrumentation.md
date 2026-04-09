# Testing Instrumentation

Patterns and practices for testing instrumented code using the `instrument_test` module.

## Quick Start with instrument_test

The `instrument_test` module provides collectors and assertions for testing spans, metrics, and logs.

### EUnit Example

```erlang
-module(my_instrumented_module_test).
-include_lib("eunit/include/eunit.hrl").
-include("instrument_otel.hrl").

my_test_() ->
    {setup,
        fun() -> instrument_test:setup() end,
        fun(_) -> instrument_test:cleanup() end,
        [
            fun test_span_creation/0,
            fun test_metric_increment/0
        ]
    }.

test_span_creation() ->
    instrument_test:reset(),

    %% Call your instrumented function
    my_module:process_request(#{id => 123}),

    %% Assert span was created with correct attributes
    instrument_test:assert_span_exists(<<"process_request">>),
    instrument_test:assert_span_attribute(<<"process_request">>, <<"request.id">>, 123),
    instrument_test:assert_span_status(<<"process_request">>, ok).

test_metric_increment() ->
    instrument_test:reset(),

    my_module:handle_event(success),

    instrument_test:assert_counter(events_total, 1.0).
```

### Common Test Example

```erlang
-module(my_instrumented_module_SUITE).
-include("instrument_otel.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([test_span_creation/1, test_nested_spans/1]).

all() -> [test_span_creation, test_nested_spans].

init_per_suite(Config) ->
    instrument_test:setup(),
    Config.

end_per_suite(_Config) ->
    instrument_test:cleanup(),
    ok.

init_per_testcase(_TestCase, Config) ->
    instrument_test:reset(),
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

test_span_creation(_Config) ->
    %% Call instrumented code
    my_module:process_request(#{id => 123}),

    %% Assertions
    instrument_test:assert_span_exists(<<"process_request">>),
    instrument_test:assert_span(<<"process_request">>, #{
        kind => server,
        status => ok,
        attributes => #{<<"request.id">> => 123}
    }),
    ok.

test_nested_spans(_Config) ->
    my_module:complex_operation(),

    %% Verify parent-child relationship
    instrument_test:assert_span_exists(<<"outer_operation">>),
    instrument_test:assert_span_exists(<<"inner_operation">>),
    instrument_test:assert_parent_child(<<"outer_operation">>, <<"inner_operation">>),
    ok.
```

## Testing Spans

### Capturing Spans

Spans are automatically captured after calling `instrument_test:setup()`:

```erlang
%% Your instrumented code
instrument_tracer:with_span(<<"my_operation">>, fun() ->
    instrument_tracer:set_attribute(<<"user.id">>, UserId),
    do_work()
end),

%% Get all captured spans
Spans = instrument_test:get_spans(),

%% Get a specific span by name
{ok, Span} = instrument_test:get_span(<<"my_operation">>),
```

### Span Assertions

```erlang
%% Assert span exists
instrument_test:assert_span_exists(<<"my_operation">>),

%% Assert span does not exist
instrument_test:assert_no_span(<<"unexpected_span">>),

%% Assert specific attribute
instrument_test:assert_span_attribute(<<"my_operation">>, <<"user.id">>, 42),

%% Assert span has an event
instrument_test:assert_span_event(<<"my_operation">>, <<"cache_miss">>),

%% Assert span status
instrument_test:assert_span_status(<<"my_operation">>, ok),
instrument_test:assert_span_status(<<"failed_op">>, error),
instrument_test:assert_span_status(<<"failed_op">>, {error, <<"timeout">>}),

%% Assert multiple properties at once
instrument_test:assert_span(<<"my_operation">>, #{
    kind => server,
    status => ok,
    attributes => #{
        <<"http.method">> => <<"GET">>,
        <<"http.status_code">> => 200
    }
}),
```

### Testing Nested Spans

```erlang
test_nested_spans(_Config) ->
    instrument_tracer:with_span(<<"parent">>, fun() ->
        instrument_tracer:with_span(<<"child">>, fun() ->
            ok
        end)
    end),

    %% Verify parent-child relationship
    instrument_test:assert_parent_child(<<"parent">>, <<"child">>),

    %% Both spans should exist
    instrument_test:assert_span_exists(<<"parent">>),
    instrument_test:assert_span_exists(<<"child">>),

    %% Get spans to verify trace IDs match
    {ok, Parent} = instrument_test:get_span(<<"parent">>),
    {ok, Child} = instrument_test:get_span(<<"child">>),
    Parent#span.ctx#span_ctx.trace_id = Child#span.ctx#span_ctx.trace_id.
```

### Testing Exception Handling

```erlang
test_exception_span(_Config) ->
    try
        instrument_tracer:with_span(<<"failing_op">>, fun() ->
            error(something_bad)
        end)
    catch
        error:something_bad -> ok
    end,

    %% Span should have error status
    instrument_test:assert_span_status(<<"failing_op">>, error),

    %% Should have exception event
    instrument_test:assert_span_event(<<"failing_op">>, <<"exception">>),

    %% Can check exception attributes
    {ok, Span} = instrument_test:get_span(<<"failing_op">>),
    [Event] = Span#span.events,
    <<"exception">> = Event#span_event.name,
    true = maps:is_key(<<"exception.type">>, Event#span_event.attributes).
```

### Testing Cross-Process Propagation

```erlang
test_cross_process_propagation(_Config) ->
    Parent = self(),

    instrument_tracer:with_span(<<"parent_process">>, fun() ->
        ParentTraceId = instrument_tracer:trace_id(),

        %% Spawn with context propagation
        Pid = instrument_propagation:spawn(fun() ->
            instrument_tracer:with_span(<<"child_process">>, fun() ->
                ChildTraceId = instrument_tracer:trace_id(),
                Parent ! {trace_id, ChildTraceId}
            end)
        end),

        receive
            {trace_id, ParentTraceId} ->
                %% Same trace ID means context was propagated
                _ = Pid,
                ok
        after 1000 ->
            ct:fail(timeout)
        end
    end),

    %% Both spans should be captured
    ok = instrument_test:wait_for_spans(2, 1000),
    instrument_test:assert_span_exists(<<"parent_process">>),
    instrument_test:assert_span_exists(<<"child_process">>).
```

### Waiting for Async Spans

```erlang
test_async_operation(_Config) ->
    %% Start async operation that creates spans
    start_background_job(),

    %% Wait for expected spans
    ok = instrument_test:wait_for_spans(3, 5000),

    %% Now assert
    instrument_test:assert_span_exists(<<"job_start">>),
    instrument_test:assert_span_exists(<<"job_process">>),
    instrument_test:assert_span_exists(<<"job_complete">>).
```

## Testing Metrics

### Counter Assertions

```erlang
test_counter(_Config) ->
    Counter = instrument_metric:new_counter(requests_total, <<"Total requests">>),
    instrument_metric:inc_counter(Counter, 5),

    instrument_test:assert_counter(requests_total, 5.0).
```

### Gauge Assertions

```erlang
test_gauge(_Config) ->
    Gauge = instrument_metric:new_gauge(active_connections, <<"Active connections">>),
    instrument_metric:set_gauge(Gauge, 42),

    instrument_test:assert_gauge(active_connections, 42.0).
```

### Histogram Assertions

```erlang
test_histogram(_Config) ->
    Hist = instrument_metric:new_histogram(request_duration, <<"Request duration">>, [0.1, 0.5, 1.0]),

    instrument_metric:observe_histogram(Hist, 0.2),
    instrument_metric:observe_histogram(Hist, 0.3),
    instrument_metric:observe_histogram(Hist, 0.8),

    %% Assert observation count
    instrument_test:assert_histogram_count(request_duration, 3),

    %% Assert sum of observations
    instrument_test:assert_histogram_sum(request_duration, 1.3).
```

### OTel Meter API Metrics

```erlang
test_otel_counter(_Config) ->
    Meter = instrument_meter:get_meter(<<"my_service">>),
    Counter = instrument_meter:create_counter(Meter, <<"otel_requests">>, #{
        description => <<"Total requests">>
    }),
    instrument_meter:add(Counter, 10),

    instrument_test:assert_counter(<<"otel_requests">>, 10.0).
```

## Testing Logs

### Log Assertions

```erlang
test_log_with_trace_context(_Config) ->
    %% Create log within a span
    instrument_tracer:with_span(<<"operation">>, fun() ->
        %% Your logging code that uses instrument_logger
        logger:info("Processing item", #{item_id => 123})
    end),

    %% Flush logs
    instrument_log_exporter:flush(),

    %% Assert log exists and has trace context
    instrument_test:assert_log_exists(<<"Processing item">>),
    instrument_test:assert_log_trace_context(<<"Processing item">>),

    %% Assert log properties
    instrument_test:assert_log(<<"Processing item">>, #{
        severity_text => <<"INFO">>,
        attributes => #{<<"item_id">> => 123}
    }).
```

## Test Isolation

### Using reset/0 Between Tests

The `reset/0` function clears all collected data without stopping collectors:

```erlang
init_per_testcase(_TestCase, Config) ->
    instrument_test:reset(),
    Config.
```

### Full Cleanup

Use `cleanup/0` for complete teardown:

```erlang
end_per_suite(_Config) ->
    instrument_test:cleanup(),
    ok.
```

### Unique Metric Names

To avoid collisions between tests, use unique metric names:

```erlang
test_counter_1(_Config) ->
    Counter = instrument_metric:new_counter(test1_counter, <<"Test 1 counter">>),
    %% ...

test_counter_2(_Config) ->
    Counter = instrument_metric:new_counter(test2_counter, <<"Test 2 counter">>),
    %% ...
```

## Advanced Patterns

### Property-Based Testing

Using PropEr for property-based tests:

```erlang
-include_lib("proper/include/proper.hrl").

prop_counter_monotonic() ->
    ?FORALL(Increments, list(pos_integer()),
        begin
            instrument_test:reset(),
            Counter = instrument_metric:new_counter(prop_counter, <<"">>),

            lists:foreach(fun(Inc) ->
                instrument_metric:inc_counter(Counter, Inc)
            end, Increments),

            Expected = float(lists:sum(Increments)),
            try
                instrument_test:assert_counter(prop_counter, Expected),
                true
            catch
                error:{assertion_failed, _} -> false
            end
        end).
```

### Integration Testing

```erlang
integration_test(_Config) ->
    %% Start your application
    application:ensure_all_started(my_app),
    instrument_test:reset(),

    %% Make HTTP request
    {ok, {{_, 200, _}, _, _}} = httpc:request(
        post,
        {"http://localhost:8080/api/orders", [], "application/json", "{}"},
        [],
        []
    ),

    %% Wait for spans (may be exported asynchronously)
    ok = instrument_test:wait_for_spans(1, 5000),

    %% Verify instrumentation
    instrument_test:assert_span_exists(<<"http_request">>),
    instrument_test:assert_span(<<"http_request">>, #{
        kind => server,
        attributes => #{
            <<"http.method">> => <<"POST">>,
            <<"http.status_code">> => 200
        }
    }).
```

### Testing with Mocks

```erlang
-include_lib("meck/include/meck.hrl").

mocked_external_call_test(_Config) ->
    meck:new(http_client, [passthrough]),
    meck:expect(http_client, request, fun(_, _, _) ->
        {ok, 200, [], <<"{\"id\": 123}">>}
    end),

    try
        my_module:call_external_api(),

        %% Verify span was created with correct attributes
        instrument_test:assert_span_exists(<<"external_api_call">>),
        instrument_test:assert_span_attribute(<<"external_api_call">>,
            <<"http.status_code">>, 200)
    after
        meck:unload(http_client)
    end.
```

## Best Practices

### Test Isolation

- Always call `reset/0` between tests
- Use unique metric names per test
- Clean up metrics after tests

### Deterministic Testing

- Use `always_on` sampler for tests (default)
- Control timing with `wait_for_spans/2`
- Mock external dependencies

### Assertion Failures

Assertion failures provide detailed context:

```erlang
%% Example failure message:
%% {assertion_failed, {span_not_found, <<"my_span">>, [<<"other_span">>]}}
%%
%% Shows: what was expected, what spans were actually captured
```

### Coverage

Ensure tests cover:

- Normal operation paths
- Error handling paths
- Edge cases (empty data, large values)
- Context propagation boundaries
- Async operations
