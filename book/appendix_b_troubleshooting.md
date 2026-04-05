# Appendix B: Troubleshooting

Common problems and their solutions.

## Traces Not Appearing

### Problem: No traces in my backend

**Check 1: Is tracing configured?**

```erlang
%% Verify configuration was initialized
instrument_config:init().

%% Check if exporter is registered
%% Add console exporter to verify spans are created
instrument_tracer:register_exporter(
    fun(Span) -> io:format("Span: ~p~n", [Span]) end
).
```

**Check 2: Is sampling dropping traces?**

```erlang
%% Temporarily enable all sampling
os:putenv("OTEL_TRACES_SAMPLER", "always_on"),
instrument_config:init().

%% Check sampling status in code
instrument_tracer:with_span(<<"test">>, fun() ->
    io:format("Recording: ~p~n", [instrument_tracer:is_recording()]),
    io:format("Sampled: ~p~n", [instrument_tracer:is_sampled()])
end).
```

**Check 3: Is the endpoint correct?**

```erlang
%% Verify OTLP endpoint
io:format("Endpoint: ~s~n", [os:getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "not set")]).

%% Test connectivity
{ok, _} = httpc:request("http://localhost:4318/v1/traces").
```

**Check 4: Is the batch processor running?**

```erlang
%% Check if batch processor is alive
whereis(instrument_span_processor_batch).

%% Force flush pending spans
instrument_span_processor:force_flush().
```

### Problem: Traces are incomplete (missing spans)

**Check 1: Context propagation**

```erlang
%% Verify context is being propagated
instrument_tracer:with_span(<<"parent">>, fun() ->
    %% Child should have same trace ID
    instrument_tracer:with_span(<<"child">>, fun() ->
        ParentTraceId = instrument_tracer:trace_id(),
        io:format("Trace ID: ~s~n", [ParentTraceId])
    end)
end).
```

**Check 2: Process boundaries**

```erlang
%% Wrong: context lost across spawn
spawn(fun() ->
    instrument_tracer:with_span(<<"orphan">>, fun() -> ok end)
end).

%% Correct: propagate context
instrument_propagation:spawn(fun() ->
    instrument_tracer:with_span(<<"connected">>, fun() -> ok end)
end).
```

**Check 3: HTTP header propagation**

```erlang
%% Debug: print injected headers
Headers = instrument_propagation:inject_headers(instrument_context:current()),
io:format("Headers: ~p~n", [Headers]).

%% Should see: [{<<"traceparent">>, <<"00-...">>}, ...]
```

## Metrics Issues

### Problem: Metrics not showing in Prometheus

**Check 1: Verify metrics exist**

```erlang
%% List all registered metrics
instrument_prometheus:format().

%% Should show your metrics in Prometheus format
```

**Check 2: Check metric names**

```erlang
%% Prometheus has naming rules
%% Names must match: [a-zA-Z_:][a-zA-Z0-9_:]*

%% Good
instrument:new_counter(http_requests_total, <<"">>).

%% Bad (will be sanitized)
instrument:new_counter('http.requests.total', <<"">>).
```

**Check 3: Verify endpoint is accessible**

```bash
curl http://localhost:8080/metrics
```

### Problem: High cardinality warnings

**Solution: Review labels**

```erlang
%% Bad: unbounded cardinality
instrument:new_counter_vec(requests, <<"">>, [user_id]).  %% Millions of users!

%% Good: bounded cardinality
instrument:new_counter_vec(requests, <<"">>, [user_tier]).  %% free, pro, enterprise
```

### Problem: Metric values seem wrong

**Check 1: Counter only increases**

```erlang
%% Counters can only increase
instrument:inc_counter(Counter, -1).  %% This won't work!

%% Use gauge for values that decrease
instrument:dec_gauge(Gauge, 1).
```

**Check 2: Histogram bucket boundaries**

```erlang
%% Observations are counted in buckets <= value
%% 0.5 goes in buckets 0.5, 0.75, 1.0, 2.5, etc.

%% Choose buckets that match your expected distribution
instrument:new_histogram(latency, <<"">>, [0.01, 0.05, 0.1, 0.5, 1.0]).
```

## Logging Issues

### Problem: Logs don't have trace context

**Check 1: Logger filter installed**

```erlang
%% Install the filter
instrument_logger:install().

%% Verify it's installed
logger:get_primary_config().
%% Should show instrument_trace_context filter
```

**Check 2: Logs are inside a span**

```erlang
%% Outside span: no trace context
logger:info("No trace context").

%% Inside span: has trace context
instrument_tracer:with_span(<<"test">>, fun() ->
    logger:info("Has trace context")
end).
```

### Problem: Logs not exported via OTLP

**Check 1: Exporter registered**

```erlang
%% Register log exporter
instrument_log_exporter:register(
    instrument_log_exporter_otlp:new(#{endpoint => "http://localhost:4318/v1/logs"})
).

%% Install with exporter mode
instrument_logger:install(#{exporter => true}).
```

## Performance Issues

### Problem: High CPU usage from tracing

**Solutions:**

1. Reduce sampling rate:
```erlang
os:putenv("OTEL_TRACES_SAMPLER", "traceidratio"),
os:putenv("OTEL_TRACES_SAMPLER_ARG", "0.1").  %% 10%
```

2. Use batch processor:
```erlang
instrument_span_processor_batch:start_link(#{
    max_queue_size => 2048,
    scheduled_delay => 5000
}).
```

3. Reduce attribute collection:
```erlang
%% Skip expensive attributes when not recording
case instrument_tracer:is_recording() of
    true -> instrument_tracer:set_attributes(expensive_computation());
    false -> ok
end.
```

### Problem: Memory growth from metrics

**Solutions:**

1. Check for cardinality explosion:
```erlang
%% Count unique label combinations
%% If growing unbounded, you have a cardinality problem
```

2. Clean up unused label combinations:
```erlang
instrument:remove_label(metric_name, [<<"old">>, <<"labels">>]).
```

3. Use views to aggregate (future feature)

## Context Issues

### Problem: Context leaking between requests

**Check: Proper detach**

```erlang
%% Wrong: context not detached
Token = instrument_context:attach(Ctx),
process_request().
%% Missing: instrument_context:detach(Token)

%% Correct: always detach
Token = instrument_context:attach(Ctx),
try
    process_request()
after
    instrument_context:detach(Token)
end.
```

### Problem: Context lost in gen_server

**Solution: Use context-aware calls**

```erlang
%% Client side
instrument_propagation:call_with_context(Server, Request).

%% Server side
handle_call({'$instrument_call', Ctx, Request}, From, State) ->
    Token = instrument_context:attach(Ctx),
    try
        %% Handle request
    after
        instrument_context:detach(Token)
    end.
```

## Common Error Messages

### "Metric not found"

The metric was not created before use:

```erlang
%% Error: using before creating
instrument:inc_counter(my_counter).  %% Returns {error, not_found}

%% Fix: create first
instrument:new_counter(my_counter, <<"Description">>),
instrument:inc_counter(my_counter).
```

### "Invalid operation"

Wrong operation for metric type:

```erlang
%% Error: histogram doesn't support inc
instrument:inc_counter(my_histogram).  %% Wrong!

%% Fix: use observe
instrument:observe_histogram(my_histogram, Value).
```

### "Connection refused" (OTLP)

Backend not running or wrong endpoint:

```bash
# Check if Jaeger/collector is running
curl http://localhost:4318/v1/traces

# Verify endpoint URL
echo $OTEL_EXPORTER_OTLP_ENDPOINT
```

## Debug Mode

Enable verbose logging for troubleshooting:

```erlang
%% Set logger level to debug
logger:set_primary_config(level, debug).

%% Add debug exporter
instrument_tracer:register_exporter(fun(Span) ->
    io:format("DEBUG SPAN: ~p~n", [Span])
end).
```

## Getting Help

If problems persist:

1. Check the [GitHub issues](https://github.com/benoitc/instrument/issues)
2. Enable debug logging and capture output
3. Create a minimal reproduction case
4. File an issue with:
   - Erlang/OTP version
   - instrument version
   - Configuration
   - Error messages
   - Steps to reproduce
