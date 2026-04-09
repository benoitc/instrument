# instrument

[![Hex.pm](https://img.shields.io/hexpm/v/instrument.svg)](https://hex.pm/packages/instrument)
[![Build Status](https://github.com/benoitc/instrument/workflows/CI/badge.svg)](https://github.com/benoitc/instrument/actions)

OpenTelemetry-compatible observability library for Erlang with high-performance NIF-based metrics.

## OpenTelemetry Compatibility

| Component | Version | Notes |
|-----------|---------|-------|
| OTLP Protocol | 1.0+ | HTTP/JSON encoding for traces, metrics, logs |
| Trace API | 1.0+ | Spans, attributes, events, links, status |
| Metrics API | 1.0+ | Counter, Gauge, Histogram with attributes |
| Context/Propagation | 1.0+ | W3C TraceContext, W3C Baggage, B3/B3Multi |
| Resource | 1.0+ | Service name, SDK info, environment detection |
| Sampling | 1.0+ | always_on, always_off, traceidratio, parentbased |

Tested with:
- Jaeger 1.50+ (OTLP receiver)
- Prometheus 2.40+ (scraping /metrics endpoint)

## Features

- **OpenTelemetry API**: Full OTel-compatible Meter and Tracer interfaces
- **Distributed Tracing**: Spans with W3C TraceContext, B3, and Baggage propagation
- **High-Performance Metrics**: NIF-based atomic counters, gauges, and histograms
- **Labeled Metrics**: Vector metrics with dimension labels (attributes)
- **Span Attributes**: Indexable metadata on spans for filtering and querying
- **Export Options**: OTLP, Prometheus, Console exporters
- **Test Framework**: Built-in collectors and assertions for testing instrumented code
- **No External Dependencies**: Pure Erlang/OTP implementation

## Installation

### rebar3

```erlang
{deps, [
    {instrument, "1.0.0"}
]}.
```

### mix (Elixir)

```elixir
{:instrument, "~> 1.0.0"}
```

## Quick Start

### OpenTelemetry API (Recommended)

```erlang
%% Get a meter for your service
Meter = instrument_meter:get_meter(<<"my_service">>),

%% Create instruments with attributes support
Counter = instrument_meter:create_counter(Meter, <<"http_requests_total">>, #{
    description => <<"Total HTTP requests">>,
    unit => <<"1">>
}),

Histogram = instrument_meter:create_histogram(Meter, <<"http_request_duration_seconds">>, #{
    description => <<"Request duration">>,
    unit => <<"s">>
}),

%% Record with attributes (dimensions)
instrument_meter:add(Counter, 1, #{method => <<"GET">>, status => 200}),
instrument_meter:record(Histogram, 0.125, #{endpoint => <<"/api/users">>}).
```

### Distributed Tracing

```erlang
%% Create spans with indexable attributes
instrument_tracer:with_span(<<"process_order">>, #{kind => server}, fun() ->
    %% Add attributes - these are indexed and queryable in backends
    instrument_tracer:set_attributes(#{
        <<"order.id">> => <<"12345">>,
        <<"customer.id">> => <<"67890">>,
        <<"order.total">> => 99.99
    }),

    %% Add timestamped events
    instrument_tracer:add_event(<<"order_validated">>),

    Result = do_work(),

    instrument_tracer:set_status(ok),
    Result
end).
```

## Standalone Metrics (Without OTel)

For simple use cases, use metrics directly without the OTel API:

### Counter

```erlang
%% Create and use a counter
Counter = instrument_metric:new_counter(requests_total, "Total requests"),
instrument_metric:inc_counter(Counter),
instrument_metric:inc_counter(Counter, 5),
Value = instrument_metric:get_counter(Counter).  %% 6.0
```

### Gauge

```erlang
%% Create and use a gauge
Gauge = instrument_metric:new_gauge(connections_active, "Active connections"),
instrument_metric:set_gauge(Gauge, 100),
instrument_metric:inc_gauge(Gauge),       %% 101
instrument_metric:dec_gauge(Gauge, 5),    %% 96
Value = instrument_metric:get_gauge(Gauge).
```

### Histogram

```erlang
%% Create with default buckets
Histogram = instrument_metric:new_histogram(request_duration_seconds, "Request duration"),

%% Or with custom buckets
Histogram2 = instrument_metric:new_histogram(response_size_bytes, "Response size",
    [100, 500, 1000, 5000, 10000]),

%% Record observations
instrument_metric:observe_histogram(Histogram, 0.125),

%% Get distribution data
#{count := Count, sum := Sum, buckets := Buckets} = instrument_metric:get_histogram(Histogram).
```

### Vector Metrics (Labeled)

Add dimensions to standalone metrics:

```erlang
%% Create vector metrics
instrument_metric:new_counter_vec(http_requests_total, "HTTP requests", [method, status]),
instrument_metric:new_gauge_vec(pool_connections, "Pool connections", [pool, state]),
instrument_metric:new_histogram_vec(db_query_duration, "Query duration", [operation]),

%% Record with labels
instrument_metric:inc_counter_vec(http_requests_total, ["GET", "200"]),
instrument_metric:set_gauge_vec(pool_connections, ["default", "active"], 10),
instrument_metric:observe_histogram_vec(db_query_duration, ["SELECT"], 0.05).
```

## Context Propagation

### W3C TraceContext (Default)

```erlang
%% Inject into outgoing request headers
Headers = instrument_propagation:inject_headers(instrument_context:current()),

%% Extract from incoming request headers
Ctx = instrument_propagation:extract_headers(IncomingHeaders),
instrument_context:attach(Ctx).
```

### B3 Propagation (Zipkin)

Configure B3 propagation for Zipkin compatibility:

```erlang
%% Via environment variable
os:putenv("OTEL_PROPAGATORS", "b3"),
instrument_config:init().

%% Or programmatically
instrument_propagator:set_propagators([instrument_propagator_b3]).
```

B3 multi-header format:

```erlang
os:putenv("OTEL_PROPAGATORS", "b3multi"),
instrument_config:init().
```

### Cross-Process Propagation

```erlang
%% Spawn with trace context preserved
instrument_propagation:spawn(fun() ->
    instrument_tracer:with_span(<<"background_task">>, fun() ->
        do_work()
    end)
end).
```

## Span Attributes

Attributes are key-value pairs attached to spans. They are indexed by observability backends, enabling filtering, grouping, and querying.

```erlang
instrument_tracer:with_span(<<"http_request">>, #{kind => server}, fun() ->
    %% Set attributes for indexing and querying
    instrument_tracer:set_attributes(#{
        %% HTTP semantic conventions
        <<"http.method">> => <<"POST">>,
        <<"http.url">> => <<"https://api.example.com/orders">>,
        <<"http.status_code">> => 201,

        %% Custom business attributes
        <<"order.id">> => OrderId,
        <<"customer.tier">> => <<"premium">>,
        <<"order.item_count">> => length(Items)
    }),

    %% These attributes can be used in your backend to:
    %% - Filter traces by customer tier
    %% - Group latencies by HTTP method
    %% - Alert on specific order patterns
    process_order(Order)
end).
```

## Prometheus Export

```erlang
%% Get Prometheus-formatted metrics
Body = instrument_prometheus:format(),
ContentType = instrument_prometheus:content_type().

%% In your HTTP handler
handle_metrics(_Req) ->
    {200, [{<<"content-type">>, ContentType}], Body}.
```

## Logger Integration

```erlang
%% Install at application start
instrument_logger:install(),

%% Logs within spans include trace_id and span_id
instrument_tracer:with_span(<<"my_operation">>, fun() ->
    logger:info("Processing request"),  %% Includes trace context
    do_work()
end).
```

## Testing Instrumentation

The `instrument_test` module provides collectors and assertions for testing instrumented code:

```erlang
-module(my_module_test).
-include_lib("eunit/include/eunit.hrl").

my_test_() ->
    {setup,
        fun() -> instrument_test:setup() end,
        fun(_) -> instrument_test:cleanup() end,
        [fun test_span_creation/0]
    }.

test_span_creation() ->
    instrument_test:reset(),

    %% Call instrumented code
    my_module:process_request(#{id => 123}),

    %% Assert span was created with correct attributes
    instrument_test:assert_span_exists(<<"process_request">>),
    instrument_test:assert_span_attribute(<<"process_request">>, <<"request.id">>, 123),
    instrument_test:assert_span_status(<<"process_request">>, ok).
```

Test metrics and logs:

```erlang
%% Assert counter value
instrument_test:assert_counter(requests_total, 5.0),

%% Assert gauge value
instrument_test:assert_gauge(active_connections, 42.0),

%% Assert log exists with trace context
instrument_test:assert_log_exists(<<"Processing request">>),
instrument_test:assert_log_trace_context(<<"Processing request">>).
```

See the [Testing Instrumentation Guide](guides/testing_instrumentation.md) for details.

## Documentation

### Erlang Observability Handbook

A step-by-step guide to instrumenting Erlang applications:

- [Introduction](book/00_introduction.md)
- [Why Observability Matters](book/01_why_observability.md)
- [Your First Metrics](book/02_first_metrics.md)
- [Adding Dimensions with Labels](book/03_labels.md)
- [Understanding Traces](book/04_understanding_traces.md)
- [Building Effective Spans](book/05_effective_spans.md)
- [Connecting Services](book/06_connecting_services.md)
- [Logs That Tell the Story](book/07_logs.md)
- [Getting Data Out](book/08_exporters.md)
- [Sampling for Scale](book/09_sampling.md)
- [Complete Example](book/10_complete_example.md)
- [Quick Reference](book/appendix_a_quick_reference.md)
- [Troubleshooting](book/appendix_b_troubleshooting.md)

### Guides

- [Getting Started Guide](guides/getting_started.md)
- [Elixir Users Guide](guides/elixir_guide.md)
- [Instrumentation Guide](guides/instrumentation_guide.md)
- [Context Propagation Guide](guides/context_propagation.md)
- [Sampling and Processing Guide](guides/sampling_and_processing.md)
- [Exporters Guide](guides/exporters.md)
- [Features Reference](guides/features.md)
- [Benchmarks](guides/benchmarks.md)

### Reference

- [Metrics Reference](guides/metrics_reference.md)
- [Tracing Reference](guides/tracing_reference.md)
- [Semantic Conventions](guides/semantic_conventions.md)
- [Testing Instrumentation](guides/testing_instrumentation.md)
- [Production Operations](guides/production_operations.md)
- [Migration Guide](guides/migration.md)

## Modules

| Module | Purpose |
|--------|---------|
| `instrument` | Standalone metrics API (counter, gauge, histogram) |
| `instrument_meter` | OpenTelemetry Meter API |
| `instrument_tracer` | Span creation and tracing |
| `instrument_context` | Context management |
| `instrument_propagation` | Cross-process/service propagation |
| `instrument_prometheus` | Prometheus export |
| `instrument_test` | Test collectors and assertions |

## Configuration

### Environment Variables

| Variable | Description |
|----------|-------------|
| `OTEL_SERVICE_NAME` | Service name for resource |
| `OTEL_TRACES_SAMPLER` | Sampler type (always_on, always_off, traceidratio, parentbased_*) |
| `OTEL_TRACES_SAMPLER_ARG` | Sampler argument (e.g., probability ratio) |
| `OTEL_PROPAGATORS` | Propagators (tracecontext, baggage, b3, b3multi) |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | OTLP endpoint URL |

### Application Config

```erlang
%% In sys.config
{instrument, [
    {service_name, <<"my_service">>},
    {sampler, {instrument_sampler_probability, #{ratio => 0.1}}}
]}.
```

## Building

```bash
rebar3 compile
rebar3 ct
rebar3 dialyzer
```

## License

MIT License - see [LICENSE](LICENSE) for details.
