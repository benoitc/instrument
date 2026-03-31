# Instrumentation Guide

This guide covers best practices for instrumenting Erlang applications with the instrument library, providing observability through metrics, traces, and logs.

## Table of Contents

1. [Overview](#overview)
2. [Metrics Instrumentation](#metrics-instrumentation)
3. [Tracing Instrumentation](#tracing-instrumentation)
4. [Context Propagation](#context-propagation)
5. [Logger Integration](#logger-integration)
6. [OTel-Compatible API](#otel-compatible-api)
7. [Best Practices](#best-practices)
8. [Examples](#examples)

## Overview

The instrument library provides three pillars of observability:

| Signal | Purpose | Module |
|--------|---------|--------|
| **Metrics** | Aggregate numerical measurements | `instrument`, `instrument_meter` |
| **Traces** | Request flow across services | `instrument_tracer` |
| **Logs** | Discrete events with context | `instrument_logger` |

All three signals can be correlated using trace context (trace_id, span_id).

## Metrics Instrumentation

### Choosing the Right Metric Type

| Metric | Use When | Examples |
|--------|----------|----------|
| **Counter** | Value only increases | Requests, errors, bytes sent |
| **Gauge** | Value goes up and down | Connections, queue size, temperature |
| **Histogram** | Measuring distributions | Latency, request size, response time |

### Counter Patterns

#### Total Counts

```erlang
%% Application startup
init_metrics() ->
    instrument:new_counter_vec(
        http_requests_total,
        "Total HTTP requests",
        [method, path, status]
    ).

%% In request handler
handle_request(Method, Path, _Req) ->
    try
        Response = process_request(Method, Path),
        Status = response_status(Response),
        instrument:inc_counter_vec(http_requests_total, [Method, Path, Status]),
        Response
    catch
        _:_ ->
            instrument:inc_counter_vec(http_requests_total, [Method, Path, "500"]),
            {error, internal_error}
    end.
```

#### Error Tracking

```erlang
init_metrics() ->
    instrument:new_counter_vec(errors_total, "Total errors", [type, module]).

%% In error handler
log_error(Type, Module, _Reason) ->
    instrument:inc_counter_vec(errors_total, [atom_to_list(Type), atom_to_list(Module)]).
```

### Gauge Patterns

#### Resource Monitoring

```erlang
init_metrics() ->
    instrument:new_gauge(memory_usage_bytes, "Current memory usage"),
    instrument:new_gauge(process_count, "Number of processes"),
    instrument:new_gauge_vec(pool_connections, "Pool connections", [pool, state]).

%% Periodic update (e.g., in a gen_server)
update_system_metrics() ->
    MemInfo = erlang:memory(),
    instrument:set_gauge(memory_usage_bytes, proplists:get_value(total, MemInfo)),
    instrument:set_gauge(process_count, erlang:system_info(process_count)).

update_pool_metrics(PoolName, Active, Idle) ->
    instrument:set_gauge_vec(pool_connections, [PoolName, "active"], Active),
    instrument:set_gauge_vec(pool_connections, [PoolName, "idle"], Idle).
```

#### In-Flight Tracking

```erlang
init_metrics() ->
    instrument:new_gauge(requests_in_flight, "Current in-flight requests").

handle_request(Req) ->
    instrument:inc_gauge(requests_in_flight),
    try
        process_request(Req)
    after
        instrument:dec_gauge(requests_in_flight)
    end.
```

### Histogram Patterns

#### Latency Measurement

```erlang
init_metrics() ->
    %% Use buckets appropriate for your SLOs
    instrument:new_histogram_vec(
        http_request_duration_seconds,
        "HTTP request duration",
        [method, path],
        [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0]
    ).

handle_request(Method, Path, Req) ->
    Start = erlang:monotonic_time(),
    try
        process_request(Req)
    after
        Duration = erlang:convert_time_unit(
            erlang:monotonic_time() - Start,
            native,
            microsecond
        ) / 1_000_000,  %% Convert to seconds
        instrument:observe_histogram_vec(
            http_request_duration_seconds,
            [Method, Path],
            Duration
        )
    end.
```

#### Size Distribution

```erlang
init_metrics() ->
    instrument:new_histogram_vec(
        http_response_size_bytes,
        "HTTP response size",
        [method, path],
        [100, 1000, 10000, 100000, 1000000]
    ).

send_response(Method, Path, Body) ->
    Size = byte_size(Body),
    instrument:observe_histogram_vec(http_response_size_bytes, [Method, Path], Size),
    Body.
```

## Tracing Instrumentation

### Span Naming Conventions

Use descriptive, low-cardinality names:

```erlang
%% Good: Operation-focused names
instrument_tracer:with_span(<<"HTTP GET /api/users">>, fun() -> ... end).
instrument_tracer:with_span(<<"db.query">>, fun() -> ... end).
instrument_tracer:with_span(<<"cache.get">>, fun() -> ... end).

%% Bad: High-cardinality names (avoid!)
instrument_tracer:with_span(<<"GET /api/users/12345">>, fun() -> ... end).  %% User ID in name
```

### Span Kinds

Set the appropriate span kind for proper visualization:

```erlang
%% Server span: handling an incoming request
instrument_tracer:with_span(<<"handle_request">>, #{kind => server}, fun() ->
    process_request(Req)
end).

%% Client span: making an outgoing request
instrument_tracer:with_span(<<"http.request">>, #{kind => client}, fun() ->
    httpc:request(Url)
end).

%% Internal span: internal processing (default)
instrument_tracer:with_span(<<"validate_input">>, #{kind => internal}, fun() ->
    validate(Input)
end).

%% Producer span: producing a message
instrument_tracer:with_span(<<"send_message">>, #{kind => producer}, fun() ->
    send_to_queue(Message)
end).

%% Consumer span: consuming a message
instrument_tracer:with_span(<<"process_message">>, #{kind => consumer}, fun() ->
    handle_message(Message)
end).
```

### Adding Indexable Attributes

Span attributes are **indexed metadata** that observability backends use for filtering, grouping, and querying. Use semantic conventions for consistent attributes:

```erlang
instrument_tracer:with_span(<<"http.request">>, #{kind => server}, fun() ->
    %% HTTP attributes - indexed for filtering/querying
    instrument_tracer:set_attributes(#{
        <<"http.method">> => Method,          %% Filter by GET/POST/etc.
        <<"http.url">> => Url,
        <<"http.target">> => Path,            %% Group latencies by endpoint
        <<"http.host">> => Host,
        <<"http.scheme">> => <<"https">>,
        <<"http.user_agent">> => UserAgent
    }),

    Response = handle(Req),

    %% Add response attributes - enables status code filtering
    instrument_tracer:set_attributes(#{
        <<"http.status_code">> => StatusCode,
        <<"http.response_content_length">> => ContentLength
    }),

    Response
end).
```

### Attribute Types and Indexing

Backends index attributes by type, enabling different query operations:

```erlang
instrument_tracer:set_attributes(#{
    %% String attributes - exact match, contains, regex
    <<"user.id">> => <<"user-12345">>,
    <<"customer.tier">> => <<"enterprise">>,

    %% Numeric attributes - range queries, aggregations
    <<"order.total">> => 299.99,
    <<"retry.count">> => 3,

    %% Boolean attributes - binary filtering
    <<"cache.hit">> => true,
    <<"auth.mfa_used">> => false
}).
```

Example queries in observability backends:
- `customer.tier = "enterprise" AND order.total > 100`
- `http.status_code >= 500`
- `cache.hit = false AND duration > 1s`

### Recording Errors

```erlang
instrument_tracer:with_span(<<"process_order">>, fun() ->
    try
        Result = do_process(Order),
        instrument_tracer:set_status(ok),
        Result
    catch
        error:Reason:Stacktrace ->
            %% Record exception details
            instrument_tracer:record_exception(Reason, #{
                stacktrace => Stacktrace
            }),
            instrument_tracer:set_status(error, <<"Order processing failed">>),
            {error, Reason}
    end
end).
```

### Adding Events

Events are timestamped annotations within a span:

```erlang
instrument_tracer:with_span(<<"process_order">>, fun() ->
    instrument_tracer:add_event(<<"order.received">>, #{
        <<"order.id">> => OrderId
    }),

    ValidatedOrder = validate(Order),
    instrument_tracer:add_event(<<"order.validated">>),

    ProcessedOrder = process(ValidatedOrder),
    instrument_tracer:add_event(<<"order.processed">>),

    save(ProcessedOrder),
    instrument_tracer:add_event(<<"order.saved">>),

    ProcessedOrder
end).
```

### Manual Span Management

When `with_span` doesn't fit your control flow:

```erlang
handle_async_operation(Data) ->
    %% Start span manually
    Span = instrument_tracer:start_span(<<"async_operation">>, #{
        attributes => #{<<"data.size">> => byte_size(Data)}
    }),

    %% Pass span context to async handler
    SpanCtx = instrument_tracer:span_ctx(Span),

    spawn(fun() ->
        %% In the spawned process, restore context
        Ctx = instrument_context:set_value(instrument_context:new(), span_ctx, SpanCtx),
        instrument_context:attach(Ctx),

        try
            do_async_work(Data),
            instrument_tracer:set_status(ok)
        catch
            _:Reason ->
                instrument_tracer:record_exception(Reason),
                instrument_tracer:set_status(error)
        after
            instrument_tracer:end_span(Span)
        end
    end).
```

## Context Propagation

### Within the Same Process

Context is automatically propagated through the process dictionary:

```erlang
instrument_tracer:with_span(<<"parent">>, fun() ->
    %% Child span automatically has parent context
    instrument_tracer:with_span(<<"child">>, fun() ->
        %% Both share the same trace_id
        do_work()
    end)
end).
```

### Across Process Boundaries

Use propagation helpers to maintain trace context:

```erlang
%% Spawning with context
instrument_tracer:with_span(<<"coordinator">>, fun() ->
    %% Context automatically propagated
    Pid = instrument_propagation:spawn(fun() ->
        %% This process has the trace context
        instrument_tracer:with_span(<<"worker">>, fun() ->
            do_work()
        end)
    end),

    %% Or spawn_link
    Pid2 = instrument_propagation:spawn_link(fun() ->
        process_task()
    end)
end).
```

### Across Service Boundaries (HTTP)

#### Injecting Context (Client Side)

```erlang
make_request(Method, Url, Body) ->
    instrument_tracer:with_span(<<"http.request">>, #{kind => client}, fun() ->
        instrument_tracer:set_attributes(#{
            <<"http.method">> => Method,
            <<"http.url">> => Url
        }),

        %% Inject trace context into headers
        Headers = instrument_propagation:inject_headers(instrument_context:current()),

        %% Make request with propagated context
        Response = httpc:request(Method, {Url, Headers, "application/json", Body}, [], []),

        Response
    end).
```

#### Extracting Context (Server Side)

```erlang
handle_request(Headers, Body) ->
    %% Extract context from incoming headers
    Ctx = instrument_propagation:extract_headers(Headers),
    instrument_context:attach(Ctx),

    %% Continue the trace
    instrument_tracer:with_span(<<"handle_request">>, #{kind => server}, fun() ->
        process(Body)
    end).
```

### Baggage Propagation

Propagate key-value pairs across service boundaries:

```erlang
%% Set baggage (propagates to downstream services)
instrument_baggage:set(<<"user.id">>, UserId),
instrument_baggage:set(<<"request.id">>, RequestId),

%% Read baggage (from upstream services)
UserId = instrument_baggage:get(<<"user.id">>),

%% Baggage is automatically included in propagation headers
Headers = instrument_propagation:inject_headers(instrument_context:current()).
```

## Logger Integration

### Installation

```erlang
%% In your application start
start(_StartType, _StartArgs) ->
    %% Install logger filter for automatic trace context
    instrument_logger:install(),

    %% Your supervisor start
    my_app_sup:start_link().
```

### Automatic Trace Correlation

Once installed, all logger calls within spans automatically include trace context:

```erlang
instrument_tracer:with_span(<<"process_order">>, fun() ->
    %% These logs automatically include trace_id and span_id
    logger:info("Starting order processing"),
    logger:info("Order validated", #{order_id => OrderId}),
    logger:warning("Inventory low", #{product_id => ProductId}),

    process_order(Order)
end).
```

Log output includes trace context:

```
2024-01-15T10:30:45.123Z [INFO] [trace_id=abc123... span_id=def456...] Starting order processing
```

### Manual Context Addition

If you need to add context manually:

```erlang
Meta = instrument_logger:add_trace_context(#{custom_field => value}),
logger:info("Message", Meta).
```

## OTel-Compatible API

For OpenTelemetry-style instrumentation:

### Meter API

```erlang
%% Get a meter
Meter = instrument_meter:get_meter(<<"my_service">>, #{
    version => <<"1.0.0">>
}),

%% Create instruments
Counter = instrument_meter:create_counter(Meter, <<"requests_total">>, #{
    description => <<"Total requests processed">>,
    unit => <<"1">>
}),

Histogram = instrument_meter:create_histogram(Meter, <<"request_duration">>, #{
    description => <<"Request duration">>,
    unit => <<"s">>,
    boundaries => [0.01, 0.05, 0.1, 0.5, 1.0, 5.0]
}),

Gauge = instrument_meter:create_gauge(Meter, <<"queue_size">>, #{
    description => <<"Current queue size">>,
    unit => <<"1">>
}),

%% Record measurements with attributes
instrument_meter:add(Counter, 1, #{method => <<"GET">>, status => 200}),
instrument_meter:record(Histogram, 0.125, #{endpoint => <<"/api/users">>}),
instrument_meter:set(Gauge, 42, #{queue => <<"default">>}).
```

### Tracer API

```erlang
%% Get a tracer
Tracer = instrument_tracer:get_tracer(<<"my_service">>, #{
    version => <<"1.0.0">>
}),

%% Create spans with full control
Span = instrument_tracer:start_span(<<"operation">>, #{
    kind => server,
    attributes => #{<<"key">> => <<"value">>},
    links => [PreviousSpanCtx]
}),

%% Modify span
instrument_tracer:set_attribute(<<"result">>, <<"success">>),
instrument_tracer:add_event(<<"checkpoint_reached">>),

%% End span
instrument_tracer:end_span(Span).
```

## Best Practices

### Metric Naming

```erlang
%% Use snake_case with unit suffix
http_request_duration_seconds    %% Good
http_requests_total              %% Good
httpRequestDuration              %% Bad (camelCase)
http_request_duration            %% Bad (missing unit)

%% Use _total suffix for counters
requests_total                   %% Good
request_count                    %% Avoid
```

### Label Cardinality

```erlang
%% Good: Low cardinality labels
[method, status_code, endpoint_pattern]

%% Bad: High cardinality labels (causes memory issues!)
[user_id, request_id, timestamp]  %% Millions of unique combinations!
```

### Span Granularity

```erlang
%% Good: Meaningful operations
instrument_tracer:with_span(<<"db.query">>, fun() -> ... end).
instrument_tracer:with_span(<<"cache.get">>, fun() -> ... end).
instrument_tracer:with_span(<<"http.request">>, fun() -> ... end).

%% Bad: Too granular
instrument_tracer:with_span(<<"parse_integer">>, fun() -> ... end).
instrument_tracer:with_span(<<"string_concat">>, fun() -> ... end).
```

### Error Handling

```erlang
%% Always set status and record exceptions
instrument_tracer:with_span(<<"operation">>, fun() ->
    try
        Result = risky_operation(),
        instrument_tracer:set_status(ok),
        Result
    catch
        Class:Reason:Stacktrace ->
            instrument_tracer:record_exception(Reason, #{stacktrace => Stacktrace}),
            instrument_tracer:set_status(error, format_error(Class, Reason)),
            erlang:raise(Class, Reason, Stacktrace)
    end
end).
```

## Examples

### Complete HTTP Server Instrumentation

```erlang
-module(my_http_handler).
-export([init/0, handle/2]).

init() ->
    %% Initialize metrics
    instrument:new_counter_vec(http_requests_total, "HTTP requests", [method, path, status]),
    instrument:new_histogram_vec(http_request_duration_seconds, "Request duration",
        [method, path], [0.001, 0.01, 0.1, 1.0, 10.0]),
    instrument:new_gauge(http_requests_in_flight, "In-flight requests"),

    %% Install logger integration
    instrument_logger:install().

handle(#{method := Method, path := Path, headers := Headers} = Req, State) ->
    %% Extract trace context from headers
    Ctx = instrument_propagation:extract_headers(Headers),
    instrument_context:attach(Ctx),

    %% Track in-flight
    instrument:inc_gauge(http_requests_in_flight),
    Start = erlang:monotonic_time(),

    instrument_tracer:with_span(<<"http.request">>, #{kind => server}, fun() ->
        instrument_tracer:set_attributes(#{
            <<"http.method">> => Method,
            <<"http.target">> => Path
        }),

        try
            {Status, Body} = process_request(Req),

            %% Record success metrics
            Duration = duration_seconds(Start),
            instrument:inc_counter_vec(http_requests_total, [Method, Path, integer_to_list(Status)]),
            instrument:observe_histogram_vec(http_request_duration_seconds, [Method, Path], Duration),

            instrument_tracer:set_attributes(#{<<"http.status_code">> => Status}),
            instrument_tracer:set_status(ok),

            {Status, Body, State}
        catch
            _:Reason:Stack ->
                Duration = duration_seconds(Start),
                instrument:inc_counter_vec(http_requests_total, [Method, Path, "500"]),
                instrument:observe_histogram_vec(http_request_duration_seconds, [Method, Path], Duration),

                instrument_tracer:record_exception(Reason, #{stacktrace => Stack}),
                instrument_tracer:set_status(error, <<"Internal server error">>),

                {500, <<"Internal Server Error">>, State}
        after
            instrument:dec_gauge(http_requests_in_flight)
        end
    end).

duration_seconds(Start) ->
    erlang:convert_time_unit(erlang:monotonic_time() - Start, native, microsecond) / 1_000_000.

process_request(#{path := <<"/api/users">>} = Req) ->
    instrument_tracer:with_span(<<"fetch_users">>, fun() ->
        Users = db_fetch_users(),
        {200, encode_json(Users)}
    end);
process_request(_) ->
    {404, <<"Not Found">>}.
```

### Database Client Instrumentation

```erlang
-module(my_db).
-export([query/2, transaction/1]).

query(SQL, Params) ->
    instrument_tracer:with_span(<<"db.query">>, #{kind => client}, fun() ->
        instrument_tracer:set_attributes(#{
            <<"db.system">> => <<"postgresql">>,
            <<"db.statement">> => sanitize_sql(SQL),
            <<"db.operation">> => extract_operation(SQL)
        }),

        Start = erlang:monotonic_time(),
        try
            Result = pgsql:query(SQL, Params),
            Duration = duration_seconds(Start),
            instrument:observe_histogram(db_query_duration_seconds, Duration),
            instrument_tracer:set_status(ok),
            Result
        catch
            _:Reason:Stack ->
                instrument:inc_counter(db_errors_total),
                instrument_tracer:record_exception(Reason, #{stacktrace => Stack}),
                instrument_tracer:set_status(error, <<"Query failed">>),
                error(Reason)
        end
    end).

transaction(Fun) ->
    instrument_tracer:with_span(<<"db.transaction">>, #{kind => client}, fun() ->
        pgsql:transaction(fun() ->
            Fun()
        end)
    end).
```

### Message Queue Consumer

```erlang
-module(my_consumer).
-export([handle_message/1]).

handle_message(#{headers := Headers, body := Body, queue := Queue}) ->
    %% Extract context from message headers
    Ctx = instrument_propagation:extract_headers(Headers),
    instrument_context:attach(Ctx),

    instrument_tracer:with_span(<<"process_message">>, #{kind => consumer}, fun() ->
        instrument_tracer:set_attributes(#{
            <<"messaging.system">> => <<"rabbitmq">>,
            <<"messaging.destination">> => Queue,
            <<"messaging.operation">> => <<"process">>
        }),

        try
            Result = process_message_body(Body),
            instrument:inc_counter_vec(messages_processed_total, [Queue, "success"]),
            instrument_tracer:set_status(ok),
            Result
        catch
            _:Reason:Stack ->
                instrument:inc_counter_vec(messages_processed_total, [Queue, "error"]),
                instrument_tracer:record_exception(Reason, #{stacktrace => Stack}),
                instrument_tracer:set_status(error),
                {error, Reason}
        end
    end).
```

---

## Summary

1. **Metrics**: Use counters for totals, gauges for current state, histograms for distributions
2. **Traces**: Wrap operations in spans, set meaningful attributes, record errors
3. **Context**: Propagate across processes and services using propagation helpers
4. **Logs**: Install logger integration for automatic trace correlation
5. **Best Practices**: Low cardinality labels, meaningful span names, proper error handling
