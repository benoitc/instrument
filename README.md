# instrument

[![Hex.pm](https://img.shields.io/hexpm/v/instrument.svg)](https://hex.pm/packages/instrument)
[![Build Status](https://github.com/benoitc/instrument/workflows/CI/badge.svg)](https://github.com/benoitc/instrument/actions)

OpenTelemetry-compatible observability library for Erlang with high-performance NIF-based metrics.

## Features

- **OpenTelemetry API**: Full OTel-compatible Meter and Tracer interfaces
- **Distributed Tracing**: Spans with W3C TraceContext, B3, and Baggage propagation
- **High-Performance Metrics**: NIF-based atomic counters, gauges, and histograms
- **Labeled Metrics**: Vector metrics with dimension labels (attributes)
- **Span Attributes**: Indexable metadata on spans for filtering and querying
- **Export Options**: OTLP, Prometheus, Console exporters
- **No External Dependencies**: Pure Erlang/OTP implementation

## Installation

### rebar3

```erlang
{deps, [
    {instrument, "0.3.0"}
]}.
```

### mix (Elixir)

```elixir
{:instrument, "~> 0.3.0"}
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
Counter = instrument:new_counter(requests_total, "Total requests"),
instrument:inc_counter(Counter),
instrument:inc_counter(Counter, 5),
Value = instrument:get_counter(Counter).  %% 6.0
```

### Gauge

```erlang
%% Create and use a gauge
Gauge = instrument:new_gauge(connections_active, "Active connections"),
instrument:set_gauge(Gauge, 100),
instrument:inc_gauge(Gauge),       %% 101
instrument:dec_gauge(Gauge, 5),    %% 96
Value = instrument:get_gauge(Gauge).
```

### Histogram

```erlang
%% Create with default buckets
Histogram = instrument:new_histogram(request_duration_seconds, "Request duration"),

%% Or with custom buckets
Histogram2 = instrument:new_histogram(response_size_bytes, "Response size",
    [100, 500, 1000, 5000, 10000]),

%% Record observations
instrument:observe_histogram(Histogram, 0.125),

%% Get distribution data
#{count := Count, sum := Sum, buckets := Buckets} = instrument:get_histogram(Histogram).
```

### Vector Metrics (Labeled)

Add dimensions to standalone metrics:

```erlang
%% Create vector metrics
instrument:new_counter_vec(http_requests_total, "HTTP requests", [method, status]),
instrument:new_gauge_vec(pool_connections, "Pool connections", [pool, state]),
instrument:new_histogram_vec(db_query_duration, "Query duration", [operation]),

%% Record with labels
instrument:inc_counter_vec(http_requests_total, ["GET", "200"]),
instrument:set_gauge_vec(pool_connections, ["default", "active"], 10),
instrument:observe_histogram_vec(db_query_duration, ["SELECT"], 0.05).
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

## Documentation

- [Getting Started Guide](guides/getting_started.md)
- [Instrumentation Guide](guides/instrumentation_guide.md)
- [Context Propagation Guide](guides/context_propagation.md)
- [Exporters Guide](guides/exporters.md)
- [Features Reference](guides/features.md)

## Modules

| Module | Purpose |
|--------|---------|
| `instrument` | Standalone metrics API (counter, gauge, histogram) |
| `instrument_meter` | OpenTelemetry Meter API |
| `instrument_tracer` | Span creation and tracing |
| `instrument_context` | Context management |
| `instrument_propagation` | Cross-process/service propagation |
| `instrument_prometheus` | Prometheus export |

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
