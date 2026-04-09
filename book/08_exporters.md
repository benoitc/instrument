# Getting Data Out

Telemetry is only useful when you can view and analyze it. This chapter covers exporting to various backends.

## Export Destinations

The `instrument` library supports multiple export formats:

| Exporter | Format | Best For |
|----------|--------|----------|
| Console | Text | Development, debugging |
| OTLP | OpenTelemetry Protocol | Jaeger, Tempo, any OTLP backend |
| Prometheus | Text/OpenMetrics | Prometheus scraping |

## Console Export

The console exporter prints telemetry to stdout. It's useful for development.

### Spans

```erlang
%% Register console span exporter
instrument_tracer:register_exporter(
    fun(Span) -> instrument_exporter_console:export(Span) end
).

%% Now spans print when they end
instrument_tracer:with_span(<<"test">>, fun() ->
    ok
end).
%% Output: Span: test (1.234ms) trace_id=abc... span_id=xyz...
```

### Metrics

```erlang
%% Format all metrics as Prometheus text
Text = instrument_prometheus:format(),
io:format("~s", [Text]).
```

### Logs

```erlang
%% Register console log exporter
instrument_log_exporter:register(instrument_log_exporter_console:new()).
instrument_logger:install(#{exporter => true}).
```

## OTLP Export

OTLP (OpenTelemetry Protocol) is the standard format for sending telemetry to backends like Jaeger, Grafana Tempo, and Honeycomb.

### Configuration

```erlang
%% Via environment variables
os:putenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318"),
os:putenv("OTEL_SERVICE_NAME", "my-service"),
instrument_config:init().
```

Or programmatically:

```erlang
%% Configure OTLP exporter
Exporter = instrument_exporter_otlp:new(#{
    endpoint => "http://localhost:4318/v1/traces",
    headers => [{<<"Authorization">>, <<"Bearer token">>}]
}).
```

### Trace Export

```erlang
%% Register OTLP span exporter
OtlpExporter = instrument_exporter_otlp:new(#{
    endpoint => "http://jaeger:4318/v1/traces"
}),
instrument_tracer:register_exporter(fun(Span) ->
    instrument_exporter_otlp:export(OtlpExporter, Span)
end).
```

### Metric Export

```erlang
%% Export metrics via OTLP
MetricExporter = instrument_metrics_exporter_otlp:new(#{
    endpoint => "http://collector:4318/v1/metrics"
}),
instrument_metrics_exporter:register(MetricExporter).
```

### Log Export

```erlang
%% Export logs via OTLP
LogExporter = instrument_log_exporter_otlp:new(#{
    endpoint => "http://collector:4318/v1/logs"
}),
instrument_log_exporter:register(LogExporter),
instrument_logger:install(#{exporter => true}).
```

## Prometheus Export

Prometheus pulls metrics by scraping an HTTP endpoint.

### Setting Up the Endpoint

```erlang
%% In your HTTP server (e.g., cowboy handler)
handle_metrics(_Req) ->
    Body = instrument_prometheus:format(),
    ContentType = instrument_prometheus:content_type(),
    {200, [{<<"content-type">>, ContentType}], Body}.
```

### Prometheus Configuration

Add a scrape target in `prometheus.yml`:

```yaml
scrape_configs:
  - job_name: 'my-erlang-app'
    static_configs:
      - targets: ['localhost:8080']
    metrics_path: '/metrics'
    scrape_interval: 15s
```

### Metric Naming for Prometheus

Prometheus has naming conventions:

```erlang
%% Good names
instrument_metric:new_counter(http_requests_total, <<"Total HTTP requests">>).
instrument_metric:new_gauge(http_active_connections, <<"Active connections">>).
instrument_metric:new_histogram(http_request_duration_seconds, <<"Request duration">>).

%% Counter: use _total suffix
%% Histogram: use _seconds or _bytes suffix
%% Gauge: describe current state
```

## Jaeger Setup

Jaeger accepts OTLP traces. Quick setup with Docker:

```bash
docker run -d --name jaeger \
  -p 16686:16686 \
  -p 4318:4318 \
  jaegertracing/all-in-one:latest
```

Configure your application:

```erlang
os:putenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318"),
os:putenv("OTEL_SERVICE_NAME", "my-service"),
instrument_config:init().
```

View traces at `http://localhost:16686`.

## Batch Processing

For production, use the batch processor to reduce overhead:

```erlang
%% Configure batch span processor
instrument_span_processor_batch:start_link(#{
    exporter => instrument_exporter_otlp:new(#{
        endpoint => "http://collector:4318/v1/traces"
    }),
    max_queue_size => 2048,
    scheduled_delay => 5000,  %% 5 seconds
    max_export_batch_size => 512
}).
```

Batch processing:
- Buffers spans in memory
- Exports in batches periodically
- Reduces network overhead
- Handles temporary backend unavailability

## Resource Configuration

Resources identify your service:

```erlang
%% Via environment
os:putenv("OTEL_SERVICE_NAME", "order-service"),
os:putenv("OTEL_SERVICE_VERSION", "1.2.3"),
os:putenv("OTEL_RESOURCE_ATTRIBUTES", "deployment.environment=production").

%% Or programmatically
Resource = instrument_resource:create(#{
    <<"service.name">> => <<"order-service">>,
    <<"service.version">> => <<"1.2.3">>,
    <<"deployment.environment">> => <<"production">>
}).
```

## Multiple Exporters

You can export to multiple destinations:

```erlang
%% Console for development
instrument_tracer:register_exporter(
    fun(Span) -> instrument_exporter_console:export(Span) end
),

%% OTLP for production
OtlpExporter = instrument_exporter_otlp:new(#{endpoint => "http://collector:4318/v1/traces"}),
instrument_tracer:register_exporter(
    fun(Span) -> instrument_exporter_otlp:export(OtlpExporter, Span) end
).
```

## Complete Setup Example

```erlang
-module(telemetry_setup).
-export([init/0]).

init() ->
    %% Configure from environment
    instrument_config:init(),

    %% Set up batch processor for traces
    {ok, _} = instrument_span_processor_batch:start_link(#{
        exporter => instrument_exporter_otlp:new(#{
            endpoint => os:getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318") ++ "/v1/traces"
        }),
        max_queue_size => 2048,
        scheduled_delay => 5000,
        max_export_batch_size => 512
    }),

    %% Set up log exporter
    case os:getenv("OTEL_EXPORTER_OTLP_ENDPOINT") of
        false ->
            %% Development: console logging
            ok;
        Endpoint ->
            %% Production: OTLP logging
            LogExporter = instrument_log_exporter_otlp:new(#{
                endpoint => Endpoint ++ "/v1/logs"
            }),
            instrument_log_exporter:register(LogExporter),
            instrument_logger:install(#{exporter => true})
    end,

    %% Set up metrics exporter
    MetricExporter = instrument_metrics_exporter_otlp:new(#{
        endpoint => os:getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318") ++ "/v1/metrics"
    }),
    instrument_metrics_exporter:register(MetricExporter),

    ok.
```

## Graceful Shutdown

Ensure all telemetry is exported before shutdown:

```erlang
%% In your application stop callback
stop(_State) ->
    %% Flush pending spans
    instrument_span_processor:force_flush(),

    %% Allow time for export
    timer:sleep(1000),
    ok.
```

## Exercise

Set up a complete observability stack:

1. Start Jaeger with Docker
2. Configure OTLP export for traces
3. Set up Prometheus metrics endpoint
4. Verify data appears in both backends

Generate some traffic and explore the UIs.

## Next Steps

Your telemetry is now flowing to backends. In the next chapter, you will learn how to control costs through sampling.
