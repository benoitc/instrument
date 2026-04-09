# Production Operations

Configuration and tuning for production deployments.

## Configuration

### Environment Variables

Configure `instrument` using OpenTelemetry-compatible environment variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `OTEL_SERVICE_NAME` | Service name for resource | `unknown_service` |
| `OTEL_SERVICE_VERSION` | Service version | none |
| `OTEL_RESOURCE_ATTRIBUTES` | Additional resource attributes | none |
| `OTEL_TRACES_SAMPLER` | Sampler type | `parentbased_always_on` |
| `OTEL_TRACES_SAMPLER_ARG` | Sampler argument | none |
| `OTEL_PROPAGATORS` | Propagators | `tracecontext,baggage` |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | OTLP endpoint | none |
| `OTEL_EXPORTER_OTLP_HEADERS` | OTLP headers | none |
| `OTEL_EXPORTER_OTLP_TIMEOUT` | Export timeout (ms) | `10000` |

### Application Configuration

```erlang
%% config/sys.config
[
    {instrument, [
        {service_name, <<"my-service">>},
        {service_version, <<"1.2.3">>},
        {sampler, {instrument_sampler_probability, #{ratio => 0.1}}},
        {span_processor, {instrument_span_processor_batch, #{
            max_queue_size => 2048,
            scheduled_delay => 5000,
            max_export_batch_size => 512
        }}}
    ]}
].
```

### Initialization

```erlang
%% In your application startup
init() ->
    %% Load configuration from environment
    instrument_config:init(),

    %% Or configure programmatically
    configure_telemetry(),
    ok.

configure_telemetry() ->
    %% Set sampler
    instrument_sampler:set_sampler({instrument_sampler_probability, #{
        ratio => get_sample_rate()
    }}),

    %% Configure batch processor
    {ok, _} = instrument_span_processor_batch:start_link(#{
        exporter => get_exporter(),
        max_queue_size => 2048,
        scheduled_delay => 5000,
        max_export_batch_size => 512
    }),

    %% Configure logging
    instrument_logger:install(#{exporter => true}),

    ok.
```

## Sampling Strategies

### Low Traffic (< 100 req/s)

Sample everything to maximize visibility:

```erlang
os:putenv("OTEL_TRACES_SAMPLER", "always_on").
```

### Medium Traffic (100-1000 req/s)

Sample a portion to balance cost and visibility:

```erlang
os:putenv("OTEL_TRACES_SAMPLER", "parentbased_traceidratio"),
os:putenv("OTEL_TRACES_SAMPLER_ARG", "0.5").  %% 50%
```

### High Traffic (> 1000 req/s)

Sample aggressively to control costs:

```erlang
os:putenv("OTEL_TRACES_SAMPLER", "parentbased_traceidratio"),
os:putenv("OTEL_TRACES_SAMPLER_ARG", "0.1").  %% 10%
```

### Adaptive Sampling

Implement custom sampling based on conditions:

```erlang
-module(adaptive_sampler).
-behaviour(instrument_sampler).
-export([should_sample/6]).

should_sample(TraceId, SpanName, Kind, Attrs, Links, Parent) ->
    Rate = case SpanName of
        <<"health_check">> -> 0.01;       %% 1% for health checks
        <<"critical_", _/binary>> -> 1.0; %% 100% for critical ops
        _ -> base_rate()
    end,

    %% Always sample errors
    Rate2 = case maps:get(<<"error">>, Attrs, false) of
        true -> 1.0;
        false -> Rate
    end,

    case rand:uniform() < Rate2 of
        true -> #sampling_result{decision = record_and_sample};
        false -> #sampling_result{decision = drop}
    end.

base_rate() ->
    %% Adjust based on current load
    case erlang:statistics(run_queue) of
        N when N > 100 -> 0.01;  %% High load: 1%
        N when N > 50 -> 0.05;   %% Medium load: 5%
        _ -> 0.1                  %% Normal: 10%
    end.
```

## Batch Processing

### Configuration

```erlang
instrument_span_processor_batch:start_link(#{
    %% Exporter to use
    exporter => instrument_exporter_otlp:new(#{
        endpoint => "http://collector:4318/v1/traces"
    }),

    %% Maximum spans to queue
    max_queue_size => 2048,

    %% Export interval (ms)
    scheduled_delay => 5000,

    %% Maximum spans per export batch
    max_export_batch_size => 512,

    %% Timeout for export (ms)
    export_timeout => 30000
}).
```

### Tuning Guidelines

| Setting | Low Latency | High Throughput |
|---------|-------------|-----------------|
| `max_queue_size` | 512 | 4096 |
| `scheduled_delay` | 1000 | 10000 |
| `max_export_batch_size` | 128 | 512 |

### Handling Backpressure

When the queue is full, new spans are dropped. Monitor this:

```erlang
%% Create metric for dropped spans
instrument_metric:new_counter(otel_dropped_spans_total, <<"Dropped spans due to backpressure">>).

%% In your batch processor wrapper
handle_queue_full(Span) ->
    instrument_metric:inc_counter(otel_dropped_spans_total),
    logger:warning("Span dropped due to queue full").
```

## Resource Management

### Memory

Monitor memory usage from metrics:

```erlang
%% Periodic memory check
check_memory() ->
    MemUsed = erlang:memory(total),
    MaxMem = 1024 * 1024 * 1024,  %% 1GB limit

    case MemUsed > MaxMem * 0.8 of
        true ->
            logger:warning("High memory usage: ~p bytes", [MemUsed]),
            %% Consider reducing sampling
            instrument_sampler:set_sampler({instrument_sampler_probability, #{
                ratio => 0.01
            }});
        false ->
            ok
    end.
```

### Cardinality Control

Monitor and limit metric cardinality:

```erlang
%% Track unique label combinations
check_cardinality() ->
    %% This is a simplified example
    Metrics = instrument_prometheus:format(),
    LineCount = length(binary:split(Metrics, <<"\n">>, [global])),

    case LineCount > 10000 of
        true ->
            logger:warning("High metric cardinality: ~p lines", [LineCount]);
        false ->
            ok
    end.
```

## Graceful Shutdown

### Flushing Telemetry

```erlang
%% In your application stop callback
stop(_State) ->
    logger:info("Shutting down, flushing telemetry"),

    %% Flush pending spans
    ok = instrument_span_processor:force_flush(),

    %% Allow time for final export
    timer:sleep(2000),

    %% Shutdown processors
    instrument_span_processor_batch:stop(),

    logger:info("Telemetry flushed"),
    ok.
```

### SIGTERM Handling

```erlang
%% In your application
init() ->
    %% Handle SIGTERM
    os:set_signal(sigterm, handle),
    loop().

handle_signal(sigterm) ->
    logger:info("Received SIGTERM"),
    application:stop(my_app).
```

## Monitoring the Telemetry System

### Self-Monitoring Metrics

```erlang
init_self_monitoring() ->
    %% Spans
    instrument_metric:new_counter(otel_spans_created_total, <<"Total spans created">>),
    instrument_metric:new_counter(otel_spans_exported_total, <<"Total spans exported">>),
    instrument_metric:new_counter(otel_spans_dropped_total, <<"Total spans dropped">>),
    instrument_metric:new_histogram(otel_export_duration_seconds, <<"Export duration">>),

    %% Queue
    instrument_metric:new_gauge(otel_queue_size, <<"Current queue size">>),

    ok.
```

### Health Checks

```erlang
%% Health check endpoint
health_check() ->
    Checks = [
        {span_processor, check_span_processor()},
        {exporter, check_exporter()},
        {queue, check_queue()}
    ],

    AllHealthy = lists:all(fun({_, Status}) -> Status == ok end, Checks),
    {AllHealthy, Checks}.

check_span_processor() ->
    case whereis(instrument_span_processor_batch) of
        undefined -> error;
        Pid when is_pid(Pid) -> ok
    end.

check_exporter() ->
    %% Verify exporter can connect
    case instrument_exporter_otlp:health_check() of
        ok -> ok;
        _ -> degraded
    end.

check_queue() ->
    %% Check queue size
    case instrument_span_processor_batch:queue_size() of
        N when N < 1000 -> ok;
        N when N < 2000 -> degraded;
        _ -> error
    end.
```

## Performance Tuning

### Reduce Overhead

```erlang
%% Skip expensive operations when not recording
instrument_tracer:with_span(<<"operation">>, fun() ->
    case instrument_tracer:is_recording() of
        true ->
            %% Full instrumentation
            instrument_tracer:set_attributes(compute_attributes());
        false ->
            %% Minimal path
            ok
    end,
    do_work()
end).
```

### Async Attribute Computation

```erlang
%% Defer expensive attributes
instrument_tracer:with_span(<<"operation">>, fun() ->
    %% Set cheap attributes immediately
    instrument_tracer:set_attribute(<<"operation.type">>, <<"query">>),

    Result = do_work(),

    %% Set expensive attributes after work completes
    case instrument_tracer:is_recording() of
        true ->
            instrument_tracer:set_attributes(#{
                <<"result.size">> => compute_size(Result)
            });
        false ->
            ok
    end,

    Result
end).
```

### Connection Pooling

For OTLP export, use connection pooling:

```erlang
%% Configure hackney pool
application:set_env(hackney, max_connections, 100),
application:set_env(hackney, timeout, 30000).

%% Create exporter with pool
Exporter = instrument_exporter_otlp:new(#{
    endpoint => "http://collector:4318/v1/traces",
    pool => otel_pool,
    pool_size => 10
}).
```

## Alerting

### Key Metrics to Alert On

```yaml
# Prometheus alerting rules
groups:
  - name: telemetry
    rules:
      - alert: HighSpanDropRate
        expr: rate(otel_spans_dropped_total[5m]) > 100
        for: 5m
        annotations:
          summary: "High span drop rate"

      - alert: ExportLatencyHigh
        expr: histogram_quantile(0.99, otel_export_duration_seconds) > 5
        for: 5m
        annotations:
          summary: "Export latency too high"

      - alert: QueueBackpressure
        expr: otel_queue_size > 1500
        for: 2m
        annotations:
          summary: "Span queue nearing capacity"
```

## Troubleshooting Production Issues

### No Traces Appearing

1. Check sampling:
   ```erlang
   io:format("Sampler: ~p~n", [os:getenv("OTEL_TRACES_SAMPLER")]).
   ```

2. Check exporter connectivity:
   ```bash
   curl -v http://collector:4318/v1/traces
   ```

3. Force flush and check logs:
   ```erlang
   instrument_span_processor:force_flush().
   ```

### High Memory Usage

1. Check cardinality:
   ```erlang
   byte_size(instrument_prometheus:format()).
   ```

2. Review label usage for high-cardinality values

3. Consider reducing `max_queue_size`

### Missing Spans

1. Verify context propagation:
   ```erlang
   Headers = instrument_propagation:inject_headers(instrument_context:current()),
   io:format("Headers: ~p~n", [Headers]).
   ```

2. Check for detach issues in error paths

3. Verify batch processor is running

## Deployment Checklist

- [ ] Set `OTEL_SERVICE_NAME`
- [ ] Configure appropriate sampling rate
- [ ] Set up batch processor with tuned settings
- [ ] Configure OTLP endpoint and authentication
- [ ] Set up health checks
- [ ] Configure alerting on telemetry metrics
- [ ] Test graceful shutdown
- [ ] Verify traces appear in backend
- [ ] Verify metrics are scraped
- [ ] Document runbook for common issues
