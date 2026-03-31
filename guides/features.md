# Instrument Features

## Overview

Instrument is an Erlang library providing high-performance metrics and tracing capabilities with OpenTelemetry compatibility.

## Feature Support Matrix

### Metrics

| Feature | Status | Description |
|---------|--------|-------------|
| Counter | Stable | Monotonically increasing cumulative metric |
| Gauge | Stable | Point-in-time measurement |
| Histogram | Stable | Distribution of values with configurable buckets |
| UpDownCounter | Stable | Counter that can increase or decrease |
| Observable Counter | Stable | Async counter with callback |
| Observable Gauge | Stable | Async gauge with callback |
| Observable UpDownCounter | Stable | Async up/down counter with callback |
| Metric Views | Stable | Transform and filter metrics during export |
| Attribute Support | Stable | Key-value dimensions for metrics |

### Tracing

| Feature | Status | Description |
|---------|--------|-------------|
| Span Creation | Stable | Create and manage trace spans |
| Context Propagation | Stable | W3C TraceContext, B3, B3Multi propagation |
| Baggage | Stable | W3C Baggage propagation |
| Samplers | Stable | AlwaysOn, AlwaysOff, Probability, ParentBased |
| Span Processors | Stable | Simple and Batch processors |
| Span Attributes | Stable | Indexable key-value metadata on spans |
| Span Events | Stable | Timestamped events within spans |
| Span Links | Stable | Connect causally related spans |

### Export

| Feature | Status | Description |
|---------|--------|-------------|
| Console Exporter | Stable | Export to stdout for debugging |
| OTLP Exporter | Stable | Export via OTLP/HTTP (protobuf) |
| File Exporter | Stable | Export logs to file |
| Prometheus Format | Stable | Compatible with Prometheus scraping |

### Context

| Feature | Status | Description |
|---------|--------|-------------|
| Process Dictionary Context | Stable | Context storage per process |
| Context Values | Stable | Get/set arbitrary context values |
| Context Propagation | Stable | Inject/extract across service boundaries |

## OpenTelemetry Specification Compliance

### Tracing API (v1.0)

| Component | Compliance | Notes |
|-----------|------------|-------|
| TracerProvider | Partial | Single global tracer |
| Tracer | Full | Start/end spans with attributes |
| Span | Full | Name, attributes, events, links, status |
| SpanContext | Full | TraceId, SpanId, TraceFlags, TraceState |
| SpanKind | Full | Internal, Server, Client, Producer, Consumer |
| SpanProcessor | Full | Simple and Batch implementations |
| Sampler | Full | AlwaysOn, AlwaysOff, TraceIdRatio, ParentBased |

### Metrics API (v1.0)

| Component | Compliance | Notes |
|-----------|------------|-------|
| MeterProvider | Partial | Single global meter provider |
| Meter | Full | Create instruments with options |
| Counter | Full | Monotonic increment only |
| UpDownCounter | Full | Bidirectional counter |
| Histogram | Full | Configurable bucket boundaries |
| Gauge | Full | Point-in-time values |
| Observable Instruments | Full | Callback-based async instruments |
| Attributes | Full | Key-value dimensions |
| Views | Full | Transform metrics during collection |

### Context and Propagation (v1.0)

| Component | Compliance | Notes |
|-----------|------------|-------|
| Context | Full | Process dictionary based |
| Propagator API | Full | Inject/extract interface |
| W3C TraceContext | Full | traceparent and tracestate headers |
| W3C Baggage | Full | baggage header |
| B3 Single Header | Full | Zipkin b3 header format |
| B3 Multi Header | Full | X-B3-* headers format |
| Composite Propagator | Full | Chain multiple propagators |

### Resource (v1.0)

| Component | Compliance | Notes |
|-----------|------------|-------|
| Resource | Full | Service name, version, etc. |
| Resource Detectors | Full | Auto-detect environment |
| Resource Merging | Full | Combine multiple resource sources |

## API Reference Summary

### Metrics API

```erlang
%% Create instruments
Meter = instrument_meter:get_meter(<<"service_name">>).
Counter = instrument_meter:create_counter(Meter, <<"requests_total">>, #{
  description => <<"Total requests">>,
  unit => <<"1">>
}).

%% Record values
instrument_meter:add(Counter, 1).
instrument_meter:add(Counter, 1, #{method => <<"GET">>}).
```

### Tracing API

```erlang
%% Create spans
Span = instrument_tracer:start_span(<<"operation_name">>).
instrument_tracer:set_attributes(Span, #{key => value}).
instrument_tracer:add_event(Span, <<"event_name">>, #{}).
instrument_tracer:end_span(Span).
```

### Context API

```erlang
%% Propagation (W3C TraceContext is default)
Carrier = instrument_propagator:inject(Context, #{}).
Context = instrument_propagator:extract(Carrier).

%% Configure B3 propagation (Zipkin compatibility)
instrument_propagator:set_propagators([instrument_propagator_b3]).

%% Or B3 multi-header format
instrument_propagator:set_propagators([instrument_propagator_b3_multi]).
```

### Span Attributes (Indexable Metadata)

Span attributes are key-value pairs that provide searchable context:

```erlang
instrument_tracer:with_span(<<"process_order">>, fun() ->
    %% Set indexable attributes - queryable in backends like Jaeger, Tempo, etc.
    instrument_tracer:set_attributes(#{
        %% String attributes
        <<"order.id">> => <<"ORD-12345">>,
        <<"customer.tier">> => <<"premium">>,

        %% Numeric attributes (for aggregation/filtering)
        <<"order.total">> => 149.99,
        <<"order.item_count">> => 3,

        %% Boolean attributes
        <<"order.express_shipping">> => true
    }),

    %% These attributes enable:
    %% - Filtering traces by customer.tier = "premium"
    %% - Aggregating latencies by order.item_count
    %% - Alerting when order.total > threshold
    process(Order)
end).
```

### Legacy API

```erlang
%% Direct counter/gauge/histogram
Counter = instrument:new_counter(name, <<"help">>).
instrument:inc_counter(Counter).

%% Vector metrics (labeled)
instrument:new_counter_vec(name, <<"help">>, [method, status]).
instrument:inc_counter_vec(name, [<<"GET">>, <<"200">>]).
```

## Configuration Options

### Application Environment

```erlang
%% In sys.config or application:set_env/3
[
  {instrument, [
    %% Resource configuration
    {resource, #{
      service_name => <<"my_service">>,
      service_version => <<"1.0.0">>
    }},

    %% Sampler configuration
    {sampler, {instrument_sampler_probability, #{ratio => 0.1}}},

    %% Span processor configuration
    {span_processor, {instrument_span_processor_batch, #{
      max_queue_size => 2048,
      scheduled_delay_ms => 5000,
      max_export_batch_size => 512
    }}},

    %% Exporter configuration
    {span_exporter, {instrument_exporter_otlp, #{
      endpoint => <<"http://localhost:4318/v1/traces">>
    }}},

    {metrics_exporter, {instrument_metrics_exporter_otlp, #{
      endpoint => <<"http://localhost:4318/v1/metrics">>
    }}}
  ]}
].
```

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `OTEL_SERVICE_NAME` | Service name for resource | `unknown_service` |
| `OTEL_RESOURCE_ATTRIBUTES` | Additional resource attributes | - |
| `OTEL_TRACES_SAMPLER` | Sampler type | `parentbased_always_on` |
| `OTEL_TRACES_SAMPLER_ARG` | Sampler argument (e.g., ratio) | - |
| `OTEL_PROPAGATORS` | Propagators: tracecontext, baggage, b3, b3multi | `tracecontext,baggage` |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | OTLP endpoint URL | `http://localhost:4318` |
| `OTEL_EXPORTER_OTLP_HEADERS` | Additional headers | - |

### Programmatic Configuration

```erlang
%% Set sampler at runtime
instrument_sampler:set_sampler(instrument_sampler_probability, #{ratio => 0.5}).

%% Register span processor
instrument_span_processor:register(instrument_span_processor_batch, #{
  exporter => instrument_exporter_otlp,
  exporter_config => #{endpoint => <<"http://collector:4318/v1/traces">>}
}).

%% Register propagators
instrument_propagator:set_propagators([
  instrument_propagator_tracecontext,
  instrument_propagator_baggage
]).

%% Register metric views
instrument_metric_view:register(#metric_view{
  instrument_name => <<"http_request_duration">>,
  name => <<"http.server.duration">>,
  attribute_keys => [<<"http.method">>, <<"http.status_code">>]
}).
```

## Performance Characteristics

- NIF-based atomic operations for counters and gauges
- Lock-free concurrent access to metrics
- Efficient histogram bucket updates with linear search (optimized for typical 10-15 buckets)
- Batch span processing to reduce export overhead
- Process dictionary context for zero-overhead context access

## Dependencies

- Erlang/OTP 24+
- `crypto` application for ID generation
- Optional: `jsx` or `jiffy` for JSON encoding (OTLP export)
