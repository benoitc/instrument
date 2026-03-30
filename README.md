# instrument

[![Hex.pm](https://img.shields.io/hexpm/v/instrument.svg)](https://hex.pm/packages/instrument)
[![Build Status](https://github.com/benoitc/instrument/workflows/CI/badge.svg)](https://github.com/benoitc/instrument/actions)

Fast metrics library for Erlang with Prometheus export. Uses NIFs for high-performance atomic counters, gauges, and histograms.

## Features

- High-performance counters, gauges, and histograms using NIFs
- Vec API for labeled metrics (prometheus-cpp style)
- Built-in Prometheus text format export
- Simple, minimal API

## Installation

### rebar3

```erlang
{deps, [
    {instrument, "0.2.0"}
]}.
```

### mix

```elixir
{:instrument, "~> 0.2.0"}
```

## Quick Start

### Counters

```erlang
%% Create a counter
Counter = instrument:new_counter(http_requests_total, "Total HTTP requests"),

%% Increment
instrument:inc_counter(Counter),
instrument:inc_counter(Counter, 5),

%% Get value
Value = instrument:get_counter(Counter).
```

### Gauges

```erlang
%% Create a gauge
Gauge = instrument:new_gauge(temperature, "Current temperature"),

%% Set, increment, decrement
instrument:set_gauge(Gauge, 23.5),
instrument:inc_gauge(Gauge),
instrument:dec_gauge(Gauge, 2),

%% Get value
Value = instrument:get_gauge(Gauge).
```

### Histograms

```erlang
%% Create with default buckets
Histogram = instrument:new_histogram(request_duration_seconds, "Request duration"),

%% Create with custom buckets
Histogram2 = instrument:new_histogram(response_size_bytes, "Response size",
    [100, 500, 1000, 5000, 10000]),

%% Observe values
instrument:observe_histogram(Histogram, 0.25),

%% Get histogram data
#{count := Count, sum := Sum, buckets := Buckets} = instrument:get_histogram(Histogram).
```

## Vec API (Labeled Metrics)

The Vec API provides labeled metrics similar to prometheus-cpp:

```erlang
%% Create a counter vec with labels
instrument:new_counter_vec(http_requests_total, "HTTP requests", [method, path]),

%% Increment with label values
instrument:inc_counter_vec(http_requests_total, ["GET", "/api/users"]),
instrument:inc_counter_vec(http_requests_total, ["POST", "/api/users"], 1),

%% Get a specific labeled metric
Counter = instrument:labels(http_requests_total, ["GET", "/api/users"]),
instrument:inc_counter(Counter),

%% Gauge vec
instrument:new_gauge_vec(connections, "Active connections", [pool]),
instrument:set_gauge_vec(connections, ["db"], 5),

%% Histogram vec
instrument:new_histogram_vec(request_duration, "Request duration", [endpoint]),
instrument:observe_histogram_vec(request_duration, ["/api"], 0.125).
```

## Prometheus Export

Export metrics in Prometheus text format:

```erlang
%% Get formatted metrics
Output = instrument_prometheus:format(),

%% Get content type for HTTP response
ContentType = instrument_prometheus:content_type().
%% Returns: <<"text/plain; version=0.0.4; charset=utf-8">>
```

Example output:

```
# HELP http_requests_total Total HTTP requests
# TYPE http_requests_total counter
http_requests_total{method="GET",path="/api"} 150
http_requests_total{method="POST",path="/api"} 42
```

## Building

```bash
rebar3 compile
```

## Running Tests

```bash
rebar3 ct
```

## License

MIT License - see [LICENSE](LICENSE) for details.
