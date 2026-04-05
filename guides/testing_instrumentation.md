# Testing Instrumentation

Patterns and practices for testing instrumented code.

## Overview

Testing instrumented code requires:

- Verifying correct span creation and attributes
- Testing metric values
- Ensuring context propagation works
- Avoiding interference between tests

## Test Setup

### Starting the Application

```erlang
-module(my_test).
-include_lib("eunit/include/eunit.hrl").

setup() ->
    application:ensure_all_started(instrument),
    ok.

cleanup(_) ->
    %% Clean up metrics
    instrument:unregister_all(),
    instrument_meter:unregister_all_instruments(),
    ok.

my_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        fun test_counter/0,
        fun test_span/0
    ]}.
```

### Isolating Tests

Clear state between tests to prevent interference:

```erlang
per_test_setup() ->
    %% Clear all metrics
    instrument:unregister_all(),
    instrument_meter:unregister_all_instruments(),

    %% Clear span exporters
    %% (depends on your exporter setup)
    ok.
```

## Testing Metrics

### Counter Tests

```erlang
counter_test() ->
    %% Create counter
    Counter = instrument:new_counter(test_counter, <<"Test">>),

    %% Initial value
    ?assertEqual(0.0, instrument:get_counter(Counter)),

    %% Increment
    instrument:inc_counter(Counter),
    ?assertEqual(1.0, instrument:get_counter(Counter)),

    %% Increment by value
    instrument:inc_counter(Counter, 5),
    ?assertEqual(6.0, instrument:get_counter(Counter)),

    %% Cleanup
    instrument:unregister(test_counter).
```

### Gauge Tests

```erlang
gauge_test() ->
    Gauge = instrument:new_gauge(test_gauge, <<"Test">>),

    instrument:set_gauge(Gauge, 100),
    ?assertEqual(100.0, instrument:get_gauge(Gauge)),

    instrument:inc_gauge(Gauge, 10),
    ?assertEqual(110.0, instrument:get_gauge(Gauge)),

    instrument:dec_gauge(Gauge, 5),
    ?assertEqual(105.0, instrument:get_gauge(Gauge)),

    instrument:unregister(test_gauge).
```

### Histogram Tests

```erlang
histogram_test() ->
    Hist = instrument:new_histogram(test_hist, <<"Test">>, [1, 5, 10]),

    instrument:observe_histogram(Hist, 0.5),
    instrument:observe_histogram(Hist, 3),
    instrument:observe_histogram(Hist, 7),

    #{count := Count, sum := Sum, buckets := Buckets} =
        instrument:get_histogram(Hist),

    ?assertEqual(3, Count),
    ?assert(abs(Sum - 10.5) < 0.001),

    %% Verify bucket counts
    ?assertEqual([{1.0, 1}, {5.0, 2}, {10.0, 3}],
        [{B, C} || {B, C} <- Buckets, B =< 10]),

    instrument:unregister(test_hist).
```

### Vector Metric Tests

```erlang
counter_vec_test() ->
    instrument:new_counter_vec(test_vec, <<"Test">>, [method, status]),

    instrument:inc_counter_vec(test_vec, [<<"GET">>, <<"200">>]),
    instrument:inc_counter_vec(test_vec, [<<"POST">>, <<"201">>]),
    instrument:inc_counter_vec(test_vec, [<<"GET">>, <<"200">>], 5),

    ?assertEqual(6.0, instrument:get_counter_vec(test_vec, [<<"GET">>, <<"200">>])),
    ?assertEqual(1.0, instrument:get_counter_vec(test_vec, [<<"POST">>, <<"201">>])),

    instrument:unregister(test_vec).
```

## Testing Traces

### Capturing Spans

Create a test exporter to capture spans:

```erlang
-module(test_span_collector).
-export([new/0, get_spans/1, clear/1, export/2]).

new() ->
    ets:new(?MODULE, [public, bag]).

get_spans(Tab) ->
    ets:tab2list(Tab).

clear(Tab) ->
    ets:delete_all_objects(Tab).

export(Tab, Span) ->
    ets:insert(Tab, {span, Span}),
    ok.
```

### Span Creation Tests

```erlang
span_test() ->
    %% Setup collector
    Collector = test_span_collector:new(),
    instrument_tracer:register_exporter(
        fun(Span) -> test_span_collector:export(Collector, Span) end
    ),

    %% Create span
    instrument_tracer:with_span(<<"test_operation">>, fun() ->
        instrument_tracer:set_attribute(<<"key">>, <<"value">>),
        ok
    end),

    %% Get captured spans
    [{span, Span}] = test_span_collector:get_spans(Collector),

    %% Verify span properties
    ?assertEqual(<<"test_operation">>, Span#span.name),
    ?assertEqual(<<"value">>, maps:get(<<"key">>, Span#span.attributes)),
    ?assertEqual(ok, Span#span.status),

    %% Cleanup
    test_span_collector:clear(Collector).
```

### Span Hierarchy Tests

```erlang
nested_spans_test() ->
    Collector = test_span_collector:new(),
    instrument_tracer:register_exporter(
        fun(Span) -> test_span_collector:export(Collector, Span) end
    ),

    instrument_tracer:with_span(<<"parent">>, fun() ->
        ParentCtx = instrument_tracer:span_ctx(),

        instrument_tracer:with_span(<<"child">>, fun() ->
            ChildCtx = instrument_tracer:span_ctx(),

            %% Same trace ID
            ?assertEqual(ParentCtx#span_ctx.trace_id, ChildCtx#span_ctx.trace_id),

            %% Different span IDs
            ?assertNotEqual(ParentCtx#span_ctx.span_id, ChildCtx#span_ctx.span_id)
        end)
    end),

    %% Verify both spans captured
    Spans = test_span_collector:get_spans(Collector),
    ?assertEqual(2, length(Spans)).
```

### Attribute Tests

```erlang
attributes_test() ->
    Collector = test_span_collector:new(),
    instrument_tracer:register_exporter(
        fun(Span) -> test_span_collector:export(Collector, Span) end
    ),

    instrument_tracer:with_span(<<"test">>, fun() ->
        instrument_tracer:set_attributes(#{
            <<"string">> => <<"value">>,
            <<"number">> => 42,
            <<"boolean">> => true
        })
    end),

    [{span, Span}] = test_span_collector:get_spans(Collector),
    Attrs = Span#span.attributes,

    ?assertEqual(<<"value">>, maps:get(<<"string">>, Attrs)),
    ?assertEqual(42, maps:get(<<"number">>, Attrs)),
    ?assertEqual(true, maps:get(<<"boolean">>, Attrs)).
```

### Event Tests

```erlang
events_test() ->
    Collector = test_span_collector:new(),
    instrument_tracer:register_exporter(
        fun(Span) -> test_span_collector:export(Collector, Span) end
    ),

    instrument_tracer:with_span(<<"test">>, fun() ->
        instrument_tracer:add_event(<<"event1">>),
        instrument_tracer:add_event(<<"event2">>, #{<<"key">> => <<"value">>})
    end),

    [{span, Span}] = test_span_collector:get_spans(Collector),
    ?assertEqual(2, length(Span#span.events)),

    [Event1, Event2] = Span#span.events,
    ?assertEqual(<<"event1">>, Event1#span_event.name),
    ?assertEqual(<<"event2">>, Event2#span_event.name),
    ?assertEqual(#{<<"key">> => <<"value">>}, Event2#span_event.attributes).
```

### Exception Tests

```erlang
exception_test() ->
    Collector = test_span_collector:new(),
    instrument_tracer:register_exporter(
        fun(Span) -> test_span_collector:export(Collector, Span) end
    ),

    ?assertError(test_error, instrument_tracer:with_span(<<"test">>, fun() ->
        error(test_error)
    end)),

    [{span, Span}] = test_span_collector:get_spans(Collector),

    %% Status should be error
    ?assertMatch({error, _}, Span#span.status),

    %% Should have exception event
    [Event] = Span#span.events,
    ?assertEqual(<<"exception">>, Event#span_event.name).
```

## Testing Context Propagation

### Process Propagation

```erlang
propagation_test() ->
    Collector = test_span_collector:new(),
    instrument_tracer:register_exporter(
        fun(Span) -> test_span_collector:export(Collector, Span) end
    ),

    instrument_tracer:with_span(<<"parent">>, fun() ->
        ParentTraceId = instrument_tracer:trace_id(),

        %% Spawn with propagation
        Pid = instrument_propagation:spawn(fun() ->
            instrument_tracer:with_span(<<"child">>, fun() ->
                ChildTraceId = instrument_tracer:trace_id(),
                ?assertEqual(ParentTraceId, ChildTraceId)
            end)
        end),

        %% Wait for child process
        monitor(process, Pid),
        receive {'DOWN', _, _, Pid, _} -> ok end
    end).
```

### Header Propagation

```erlang
header_propagation_test() ->
    instrument_tracer:with_span(<<"sender">>, fun() ->
        OriginalTraceId = instrument_tracer:trace_id(),

        %% Inject into headers
        Ctx = instrument_context:current(),
        Headers = instrument_propagation:inject_headers(Ctx),

        %% Simulate receiving service
        ReceivedCtx = instrument_propagation:extract_headers(Headers),
        Token = instrument_context:attach(ReceivedCtx),

        try
            instrument_tracer:with_span(<<"receiver">>, fun() ->
                ReceiverTraceId = instrument_tracer:trace_id(),
                ?assertEqual(OriginalTraceId, ReceiverTraceId)
            end)
        after
            instrument_context:detach(Token)
        end
    end).
```

## Testing with Mocks

### Mocking External Calls

```erlang
-include_lib("meck/include/meck.hrl").

external_call_test() ->
    meck:new(http_client, [passthrough]),
    meck:expect(http_client, request, fun(_, _, _) ->
        {ok, 200, [], <<"{\"id\": 123}">>}
    end),

    Collector = test_span_collector:new(),
    instrument_tracer:register_exporter(
        fun(Span) -> test_span_collector:export(Collector, Span) end
    ),

    try
        %% Call your instrumented function
        Result = my_module:call_external_api(),

        %% Verify result
        ?assertEqual({ok, 123}, Result),

        %% Verify span was created with correct attributes
        Spans = test_span_collector:get_spans(Collector),
        [{span, Span}] = [S || {span, S} <- Spans, S#span.name == <<"call_api">>],

        ?assertEqual(200, maps:get(<<"http.status_code">>, Span#span.attributes))
    after
        meck:unload(http_client)
    end.
```

## Property-Based Testing

Using PropEr for property-based tests:

```erlang
-include_lib("proper/include/proper.hrl").

prop_counter_monotonic() ->
    ?FORALL(Increments, list(pos_integer()),
        begin
            Counter = instrument:new_counter(prop_counter, <<"">>),

            lists:foreach(fun(Inc) ->
                instrument:inc_counter(Counter, Inc)
            end, Increments),

            Expected = lists:sum(Increments),
            Actual = instrument:get_counter(Counter),

            instrument:unregister(prop_counter),
            abs(Actual - Expected) < 0.001
        end).

prop_histogram_count() ->
    ?FORALL(Values, non_empty(list(float())),
        begin
            Hist = instrument:new_histogram(prop_hist, <<"">>),

            lists:foreach(fun(V) ->
                instrument:observe_histogram(Hist, abs(V))
            end, Values),

            #{count := Count} = instrument:get_histogram(Hist),
            instrument:unregister(prop_hist),

            Count == length(Values)
        end).
```

## Integration Testing

### Full Request Test

```erlang
integration_test() ->
    %% Start application
    application:ensure_all_started(my_app),

    %% Setup span collector
    Collector = test_span_collector:new(),
    instrument_tracer:register_exporter(
        fun(Span) -> test_span_collector:export(Collector, Span) end
    ),

    %% Make request
    {ok, Status, _, Body} = hackney:request(
        post,
        "http://localhost:8080/orders",
        [{<<"Content-Type">>, <<"application/json">>}],
        jiffy:encode(#{items => [#{name => <<"Widget">>, price => 10}]}),
        []
    ),

    %% Verify response
    ?assertEqual(201, Status),

    %% Wait for async span export
    timer:sleep(100),

    %% Verify spans
    Spans = [S || {span, S} <- test_span_collector:get_spans(Collector)],

    %% Should have HTTP span
    HttpSpans = [S || S <- Spans, S#span.name == <<"http_request">>],
    ?assertEqual(1, length(HttpSpans)),

    %% Verify attributes
    [HttpSpan] = HttpSpans,
    ?assertEqual(201, maps:get(<<"http.status_code">>, HttpSpan#span.attributes)).
```

## Best Practices

### Test Isolation

- Clear state between tests
- Use unique metric names per test
- Unregister metrics after tests

### Deterministic Testing

- Mock time-based operations
- Control sampling (use always_on for tests)
- Use deterministic IDs when needed

### Performance Testing

```erlang
perf_test() ->
    Counter = instrument:new_counter(perf_counter, <<"">>),

    {Time, _} = timer:tc(fun() ->
        lists:foreach(fun(_) ->
            instrument:inc_counter(Counter)
        end, lists:seq(1, 100000))
    end),

    %% Should complete in reasonable time
    ?assert(Time < 1000000),  %% Less than 1 second

    instrument:unregister(perf_counter).
```

### Coverage

Ensure tests cover:

- Normal operation paths
- Error handling paths
- Edge cases (empty data, large values)
- Context propagation boundaries
