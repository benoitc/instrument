# instrument

[![Hex.pm](https://img.shields.io/hexpm/v/instrument.svg)](https://hex.pm/packages/instrument)
[![Build Status](https://github.com/benoitc/instrument/workflows/CI/badge.svg)](https://github.com/benoitc/instrument/actions)

Fast metrics and tracing library for Erlang with Prometheus export. Uses NIFs for high-performance atomic counters, gauges, and histograms.

## Features

- **High-Performance Metrics**: Counters, gauges, and histograms using NIFs
- **Labeled Metrics**: Vector metrics with dimension labels
- **Prometheus Export**: Built-in text format export
- **OpenTelemetry API**: OTel-compatible Meter and Tracer interfaces
- **Distributed Tracing**: Spans with W3C TraceContext propagation
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

## Metrics

### Basic Metrics

```erlang
%% Counter - monotonically increasing
Counter = instrument:new_counter(http_requests_total, "Total HTTP requests"),
instrument:inc_counter(Counter),
instrument:inc_counter(Counter, 5),

%% Gauge - point-in-time value
Gauge = instrument:new_gauge(active_connections, "Current connections"),
instrument:set_gauge(Gauge, 100),
instrument:inc_gauge(Gauge),

%% Histogram - value distribution
Histogram = instrument:new_histogram(request_duration_seconds, "Request duration"),
instrument:observe_histogram(Histogram, 0.125).
```

### Labeled Metrics

```erlang
%% Create with labels
instrument:new_counter_vec(http_requests_total, "HTTP requests", [method, status]),

%% Increment specific label combination
instrument:inc_counter_vec(http_requests_total, ["GET", "200"]),
instrument:inc_counter_vec(http_requests_total, ["POST", "201"]).
```

### OpenTelemetry Meter API

For OpenTelemetry-style instrumentation with attributes:

```erlang
%% Get a meter
Meter = instrument_meter:get_meter(<<"my_service">>),

%% Create instruments
Counter = instrument_meter:create_counter(Meter, <<"requests_total">>, #{
    description => <<"Total requests">>,
    unit => <<"1">>
}),
Histogram = instrument_meter:create_histogram(Meter, <<"request_duration">>, #{
    unit => <<"ms">>
}),

%% Record with attributes
instrument_meter:add(Counter, 1, #{method => <<"GET">>, status => 200}),
instrument_meter:record(Histogram, 42.5, #{endpoint => <<"/api/users">>}).
```

### Prometheus Export

```erlang
%% Get Prometheus-formatted metrics
Body = instrument_prometheus:format(),
ContentType = instrument_prometheus:content_type().
```

## Tracing

### Creating Spans

```erlang
%% Simple span
instrument_tracer:with_span(<<"process_order">>, fun() ->
    instrument_tracer:set_attributes(#{<<"order.id">> => OrderId}),
    process_order(Order)
end).

%% Nested spans (automatic parent-child linking)
instrument_tracer:with_span(<<"handle_request">>, fun() ->
    instrument_tracer:with_span(<<"validate">>, fun() -> validate(Input) end),
    instrument_tracer:with_span(<<"process">>, fun() -> process(Data) end)
end).

%% With options
instrument_tracer:with_span(<<"operation">>, #{kind => server}, fun() ->
    instrument_tracer:set_status(ok),
    do_work()
end).
```

### Context Propagation

```erlang
%% Spawn with trace context preserved
instrument_propagation:spawn(fun() ->
    instrument_tracer:with_span(<<"background_task">>, fun() ->
        do_work()
    end)
end).

%% HTTP propagation (W3C TraceContext)
%% Inject into outgoing request
Headers = instrument_propagation:inject_headers(instrument_context:current()),

%% Extract from incoming request
Ctx = instrument_propagation:extract_headers(IncomingHeaders),
instrument_context:attach(Ctx).
```

### Logger Integration

```erlang
%% Install at application start
instrument_logger:install(),

%% Logs within spans include trace_id and span_id
instrument_tracer:with_span(<<"my_operation">>, fun() ->
    logger:info("Processing request"),
    do_work()
end).
```

## Documentation

- [Getting Started Guide](guides/getting_started.md)
- [Instrumentation Guide](guides/instrumentation_guide.md)
- [Context Propagation Guide](guides/context_propagation.md)
- [Exporters Guide](guides/exporters.md)

## Modules

| Module | Purpose |
|--------|---------|
| `instrument` | Core metrics API |
| `instrument_meter` | OpenTelemetry Meter API |
| `instrument_tracer` | Span creation and tracing |
| `instrument_context` | Context management |
| `instrument_propagation` | Cross-process propagation |
| `instrument_prometheus` | Prometheus export |

## Building

```bash
rebar3 compile
rebar3 ct
rebar3 dialyzer
```

## License

MIT License - see [LICENSE](LICENSE) for details.
