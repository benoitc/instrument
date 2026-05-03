# Understanding Traces

Metrics tell you what is happening across the system. Traces show what happened inside one request, job, or workflow.

## What is a Trace?

A trace represents a request's journey through your system. It captures:

- Which operations executed
- How long each took
- How operations relate to each other
- What context was available

## Anatomy of a Trace

### Trace ID

Every trace has a unique identifier:

```
Trace ID: 4bf92f3577b34da6a3ce929d0e0e4736
```

Every span that belongs to the same request shares this ID.

### Spans

A span represents one unit of work. Each span has:

- **Name**: What operation this is (e.g., `process_order`)
- **Start time**: When it began
- **Duration**: How long it took
- **Span ID**: Unique identifier for this span
- **Parent span ID**: The span that created this one (if any)

### Span Tree

Spans form a tree that shows the flow of work:

```
handle_request (100ms)
├── validate_input (5ms)
├── fetch_user (20ms)
│   └── db_query (15ms)
├── process_data (50ms)
│   ├── calculate (30ms)
│   └── transform (15ms)
└── send_response (10ms)
```

## Creating Your First Span

The usual way to create a span is `with_span`:

```erlang
instrument_tracer:with_span(<<"process_order">>, fun() ->
    %% Your code here
    Result = do_processing(),
    Result
end).
```

This creates a span named `process_order`. It:
- Starts when the function begins
- Ends when the function returns
- Captures the duration automatically
- Records exceptions if they occur

## See It In Action

Here is a complete example you can paste into an Erlang shell:

```erlang
-module(trace_demo).
-export([run/0]).

run() ->
    application:ensure_all_started(instrument),

    %% Register console exporter to see spans
    instrument_exporter:register(instrument_exporter_console:new()),

    instrument_tracer:with_span(<<"process_order">>, fun() ->
        instrument_tracer:set_attribute(<<"order.id">>, <<"ORD-123">>),

        instrument_tracer:with_span(<<"validate">>, fun() ->
            timer:sleep(10)
        end),

        instrument_tracer:with_span(<<"save">>, fun() ->
            timer:sleep(20)
        end),

        instrument_tracer:set_status(ok)
    end).
```

Run it:

```
1> c(trace_demo).
2> trace_demo:run().
```

Expected output:

```
=== SPAN ===
Name:       validate
TraceId:    a1b2c3d4e5f67890a1b2c3d4e5f67890
SpanId:     1234abcd5678efgh
ParentId:   5678efgh1234abcd
Kind:       internal
Duration:   10.25ms
Status:     UNSET
============

=== SPAN ===
Name:       save
TraceId:    a1b2c3d4e5f67890a1b2c3d4e5f67890  <-- Same trace ID!
SpanId:     9abc12345def6789
ParentId:   5678efgh1234abcd                   <-- Same parent
Kind:       internal
Duration:   20.18ms
Status:     UNSET
============

=== SPAN ===
Name:       process_order
TraceId:    a1b2c3d4e5f67890a1b2c3d4e5f67890
SpanId:     5678efgh1234abcd
ParentId:   none
Kind:       internal
Duration:   32.45ms
Status:     OK
Attributes: order.id = ORD-123
============
```

All three spans share the same `TraceId`. The `validate` and `save` spans both have `process_order` as their parent, so the backend can reconstruct the request tree.

## Span Context

The span context carries the trace and span IDs needed to connect spans:

```erlang
%% Get the current span context
SpanCtx = instrument_tracer:span_ctx().

%% Get individual IDs
TraceId = instrument_tracer:trace_id().   %% <<"4bf92f3577b34da6...">>
SpanId = instrument_tracer:span_id().      %% <<"00f067aa0ba902b7">>
```

## Span Kinds

Spans have a "kind" that describes their role in the larger workflow:

| Kind | Use Case |
|------|----------|
| `internal` | Default. Work within a service |
| `server` | Handling an incoming request |
| `client` | Making an outgoing request |
| `producer` | Sending a message to a queue |
| `consumer` | Receiving a message from a queue |

Set the kind when creating a span:

```erlang
%% Server span for incoming HTTP request
instrument_tracer:with_span(<<"handle_http">>, #{kind => server}, fun() ->
    process_request()
end).

%% Client span for outgoing HTTP request
instrument_tracer:with_span(<<"call_api">>, #{kind => client}, fun() ->
    make_http_request()
end).
```

## Nested Spans

When you create a span inside another span, the new span becomes a child automatically:

```erlang
instrument_tracer:with_span(<<"handle_request">>, fun() ->
    %% This span is a child of handle_request
    instrument_tracer:with_span(<<"validate">>, fun() ->
        validate(Input)
    end),

    %% This is also a child of handle_request
    instrument_tracer:with_span(<<"process">>, fun() ->
        %% This is a grandchild
        instrument_tracer:with_span(<<"transform">>, fun() ->
            transform(Data)
        end)
    end)
end).
```

## Trace Context Propagation

For distributed systems, trace context must travel with the work. Otherwise each service creates a separate trace and you lose the full picture.

### Between Processes

Use `instrument_propagation` to preserve context across process boundaries:

```erlang
%% Spawn with context propagated
instrument_propagation:spawn(fun() ->
    %% This process has the same trace context
    instrument_tracer:with_span(<<"background_task">>, fun() ->
        do_background_work()
    end)
end).
```

### Between Services

Inject context into HTTP headers for service-to-service calls:

```erlang
%% Sending service
Headers = instrument_propagation:inject_headers(instrument_context:current()),
%% Headers now contains traceparent and tracestate

%% Receiving service
Ctx = instrument_propagation:extract_headers(IncomingHeaders),
instrument_context:attach(Ctx),
%% Now spans will be children of the calling service's span
```

Chapter 6 covers this in detail.

## The Current Span

The library tracks the current span in the process dictionary:

```erlang
%% Get the current span
Span = instrument_tracer:current_span().

%% Check if we're inside a span
case instrument_tracer:current_span() of
    undefined -> not_tracing;
    _Span -> tracing
end.

%% Check if the current span is being recorded
IsRecording = instrument_tracer:is_recording().

%% Check if the current span is sampled
IsSampled = instrument_tracer:is_sampled().
```

## Manual Span Management

Sometimes you need more control than `with_span` provides:

```erlang
%% Start a span manually
Span = instrument_tracer:start_span(<<"manual_operation">>),

try
    do_work(),
    instrument_tracer:set_status(ok)
catch
    _:Error ->
        instrument_tracer:record_exception(Error),
        instrument_tracer:set_status(error)
after
    %% Always end the span
    instrument_tracer:end_span(Span)
end.
```

Use `with_span` when you can. It keeps the common case simple and handles exceptions and cleanup for you.

## When to Create Spans

**Create spans for:**
- Incoming requests (HTTP, gRPC, message handlers)
- Outgoing requests (HTTP calls, database queries)
- Significant internal operations
- Background jobs and scheduled tasks

**Don't create spans for:**
- Trivial operations (simple math, data access)
- Tight loops (creates too much overhead)
- Every function call (too noisy)

A useful rule is to create spans for operations you might later need to debug, explain, or optimize.

## Exercise

Create a trace for a simple workflow:

```erlang
-module(order_processor).
-export([process/1]).

process(Order) ->
    %% Add tracing to this workflow
    validate(Order),
    Items = fetch_items(Order),
    Total = calculate_total(Items),
    save_order(Order, Items, Total).
```

1. Create a root span for `process/1`
2. Create child spans for each step
3. Set the appropriate span kind
4. Print the trace ID

## Next Steps

You now understand the shape of a trace. In the next chapter, you will make spans more useful by adding attributes, events, and status.
