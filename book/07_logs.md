# Logs That Tell the Story

Logs are the most detailed form of telemetry. When correlated with traces, they become powerful debugging tools.

## The Problem with Logs

Traditional logs are isolated. When debugging, you:

1. Find an error in logs
2. Try to find related logs by timestamp
3. Hope you can piece together what happened

With trace correlation:

1. Find the problematic trace
2. See all logs for that exact request
3. Understand the full context

## Logger Integration

The `instrument_logger` module integrates with Erlang's logger to add trace context automatically.

### Installation

```erlang
%% In your application startup
instrument_logger:install().
```

This installs a logger filter that adds `trace_id` and `span_id` to all log metadata.

### Basic Usage

```erlang
instrument_tracer:with_span(<<"process_order">>, fun() ->
    %% These logs automatically include trace context
    logger:info("Starting order processing"),
    logger:info("Order validated", #{order_id => OrderId}),

    case process(Order) of
        ok ->
            logger:info("Order completed");
        {error, Reason} ->
            logger:error("Order failed: ~p", [Reason])
    end
end).
```

Output includes trace context:

```
2024-01-15T10:30:00.123Z [INFO] [trace_id=abc... span_id=xyz...] Starting order processing
2024-01-15T10:30:00.125Z [INFO] [trace_id=abc... span_id=xyz...] Order validated
```

## Manual Context Addition

If you prefer not to install the global filter:

```erlang
%% Add trace context to metadata manually
Meta = instrument_logger:add_trace_context(#{}),
logger:info("Processing request", Meta).
```

## Log Exporter

For backends that support the OpenTelemetry Logs data model, use the exporter mode:

```erlang
%% Register a log exporter
instrument_log_exporter:register(instrument_log_exporter_console:new()).

%% Install with exporter enabled
instrument_logger:install(#{exporter => true}).
```

This converts Erlang logs to OTel log records with proper severity mapping:

| Erlang Level | OTel Severity |
|--------------|---------------|
| emergency    | FATAL         |
| alert        | FATAL         |
| critical     | ERROR         |
| error        | ERROR         |
| warning      | WARN          |
| notice       | INFO          |
| info         | INFO          |
| debug        | DEBUG         |

## Structured Logging

Use maps for structured log data:

```erlang
instrument_tracer:with_span(<<"http_request">>, fun() ->
    logger:info(#{
        msg => "Request received",
        method => Method,
        path => Path,
        headers => Headers
    }),

    %% Or with format strings
    logger:info("Processing ~s ~s", [Method, Path], #{
        method => Method,
        path => Path
    })
end).
```

## Logging Best Practices

### What to Log

**Do log:**
- Request/response boundaries
- Business events (order created, payment processed)
- Errors with context
- Configuration changes
- Security events (login, access denied)

**Don't log:**
- Every function entry/exit (use spans)
- Sensitive data (passwords, tokens)
- High-frequency operations in tight loops

### Log Levels

Use levels appropriately:

```erlang
%% DEBUG: Detailed information for debugging
logger:debug("Cache lookup for key ~p", [Key]).

%% INFO: Normal operations worth noting
logger:info("User ~s logged in", [UserId]).

%% NOTICE: Normal but significant
logger:notice("Configuration reloaded").

%% WARNING: Something unexpected but handled
logger:warning("Retrying failed request, attempt ~p", [Attempt]).

%% ERROR: Something failed
logger:error("Database connection failed: ~p", [Reason]).

%% CRITICAL: System is in trouble
logger:critical("Out of memory, dropping messages").
```

### Context in Logs

Include relevant context without duplicating span attributes:

```erlang
instrument_tracer:with_span(<<"process_order">>, fun() ->
    %% Span already has order.id attribute
    instrument_tracer:set_attribute(<<"order.id">>, OrderId),

    %% Log adds detail not in span
    logger:info("Order has ~p items, total $~.2f", [ItemCount, Total])
end).
```

## Correlating Logs and Traces

### In Your Backend

Most observability backends support trace-to-log correlation:

1. **Jaeger + Elasticsearch**: Click on a span to see related logs
2. **Grafana + Loki**: Use the trace ID to query logs
3. **Datadog**: Logs and traces are automatically correlated

Query logs by trace ID:

```
trace_id:4bf92f3577b34da6a3ce929d0e0e4736
```

### OTLP Log Export

For full OTel log support, configure OTLP export:

```erlang
%% Configure OTLP endpoint
os:putenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://collector:4318").

%% Register OTLP log exporter
instrument_log_exporter:register(
    instrument_log_exporter_otlp:new(#{
        endpoint => "http://collector:4318/v1/logs"
    })
).

%% Install with exporter
instrument_logger:install(#{exporter => true}).
```

## File-based Log Export

For JSON log files compatible with log aggregators:

```erlang
%% Export logs to file
instrument_log_exporter:register(
    instrument_log_exporter_file:new(#{
        path => "/var/log/myapp/otel.log",
        format => json
    })
).
```

## Emitting Logs Directly

Use `instrument_logger:emit/2` for logs that should always include trace context:

```erlang
%% Emit with automatic trace context
instrument_logger:emit(info, "Custom log message").
instrument_logger:emit(error, #{error => Reason, context => Ctx}).
```

## Complete Example

```erlang
-module(payment_processor).
-export([process/2]).

process(Order, PaymentMethod) ->
    instrument_tracer:with_span(<<"process_payment">>, fun() ->
        instrument_tracer:set_attributes(#{
            <<"order.id">> => Order#order.id,
            <<"payment.method">> => PaymentMethod
        }),

        logger:info("Starting payment processing", #{
            amount => Order#order.total,
            currency => Order#order.currency
        }),

        case validate_payment_method(PaymentMethod) of
            {error, invalid} ->
                logger:warning("Invalid payment method: ~s", [PaymentMethod]),
                instrument_tracer:set_status(error, <<"Invalid payment method">>),
                {error, invalid_payment_method};

            ok ->
                logger:debug("Payment method validated"),

                case charge_card(Order, PaymentMethod) of
                    {ok, TransactionId} ->
                        logger:info("Payment successful", #{
                            transaction_id => TransactionId
                        }),
                        instrument_tracer:set_attribute(
                            <<"payment.transaction_id">>, TransactionId
                        ),
                        instrument_tracer:set_status(ok),
                        {ok, TransactionId};

                    {error, declined} ->
                        logger:warning("Payment declined by provider"),
                        instrument_tracer:add_event(<<"payment_declined">>),
                        instrument_tracer:set_status(error, <<"Payment declined">>),
                        {error, declined};

                    {error, Reason} ->
                        logger:error("Payment failed: ~p", [Reason]),
                        instrument_tracer:record_exception(Reason),
                        instrument_tracer:set_status(error),
                        {error, Reason}
                end
        end
    end).
```

## Logging Across Processes

Here is a complete runnable example showing log correlation across multiple spawned processes:

```erlang
-module(log_trace_demo).
-export([run/0]).

run() ->
    application:ensure_all_started(instrument),
    instrument_logger:install(),  %% Adds trace context to all logs

    instrument_tracer:with_span(<<"main_task">>, fun() ->
        logger:info("Starting main task"),

        %% Spawn 3 workers, all with same trace
        Pids = [instrument_propagation:spawn(fun() ->
            instrument_tracer:with_span(<<"worker">>, fun() ->
                logger:info("Worker ~p processing", [self()]),
                timer:sleep(rand:uniform(100)),
                logger:info("Worker ~p done", [self()])
            end)
        end) || _ <- lists:seq(1, 3)],

        %% Wait for all workers
        [begin
            monitor(process, P),
            receive {'DOWN', _, _, P, _} -> ok end
        end || P <- Pids],

        logger:info("All workers complete")
    end).
```

Run it:

```
1> c(log_trace_demo).
2> log_trace_demo:run().
```

Output shows ALL logs share the same trace_id:

```
[INFO] [trace_id=abc123def456... span_id=1111aaaa...] Starting main task
[INFO] [trace_id=abc123def456... span_id=2222bbbb...] Worker <0.123.0> processing
[INFO] [trace_id=abc123def456... span_id=3333cccc...] Worker <0.124.0> processing
[INFO] [trace_id=abc123def456... span_id=4444dddd...] Worker <0.125.0> processing
[INFO] [trace_id=abc123def456... span_id=2222bbbb...] Worker <0.123.0> done
[INFO] [trace_id=abc123def456... span_id=3333cccc...] Worker <0.124.0> done
[INFO] [trace_id=abc123def456... span_id=4444dddd...] Worker <0.125.0> done
[INFO] [trace_id=abc123def456... span_id=1111aaaa...] All workers complete
```

Key observations:
- **Same trace_id** in all log lines - you can query all logs for this request
- **Different span_ids** - each worker has its own span for granular timing
- The main task logs use span_id `1111aaaa...`, workers have their own span_ids

This pattern is essential for debugging distributed workflows. When something fails, search your logs by `trace_id` to see everything that happened across all processes.

## Exercise

Add logging to your order processing system:

1. Install the logger integration
2. Add appropriate log statements at each stage
3. Use different log levels based on severity
4. Verify logs include trace_id and span_id

Query your logs by trace ID to see all logs for a single order.

## Next Steps

Your logs and traces are now connected. In the next chapter, you will learn how to export this data to various backends.
