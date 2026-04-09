# Metrics Reference

Complete API reference for the metrics system.

## Overview

The `instrument` library provides two APIs for metrics:

1. **Simple API** (`instrument` module) - Direct metric manipulation
2. **OTel API** (`instrument_meter` module) - OpenTelemetry-compatible interface

Both APIs use the same high-performance NIF backend.

## Simple API

### Counters

Counters track cumulative values that only increase.

#### `instrument_metric:new_counter/2`

Creates a new counter metric.

```erlang
-spec new_counter(Name, Help) -> Counter when
    Name :: metric_name(),
    Help :: binary() | string(),
    Counter :: metric().
```

**Example:**

```erlang
Counter = instrument_metric:new_counter(http_requests_total, <<"Total HTTP requests">>).
```

#### `instrument_metric:inc_counter/1`

Increments a counter by 1.

```erlang
-spec inc_counter(Counter) -> ok | {error, not_found} when
    Counter :: metric().
```

#### `instrument_metric:inc_counter/2`

Increments a counter by a specific value.

```erlang
-spec inc_counter(Counter, Value) -> ok | {error, not_found} when
    Counter :: metric(),
    Value :: number().
```

**Note:** Value must be non-negative.

#### `instrument_metric:get_counter/1`

Returns the current counter value.

```erlang
-spec get_counter(Counter) -> float() | {error, not_found} when
    Counter :: metric().
```

### Gauges

Gauges track values that can increase or decrease.

#### `instrument_metric:new_gauge/2`

Creates a new gauge metric.

```erlang
-spec new_gauge(Name, Help) -> Gauge when
    Name :: metric_name(),
    Help :: binary() | string(),
    Gauge :: metric().
```

#### `instrument_metric:set_gauge/2`

Sets the gauge to a specific value.

```erlang
-spec set_gauge(Gauge, Value) -> ok | {error, not_found} when
    Gauge :: metric(),
    Value :: number().
```

#### `instrument_metric:inc_gauge/1`, `instrument_metric:inc_gauge/2`

Increments the gauge.

```erlang
-spec inc_gauge(Gauge) -> ok | {error, not_found}.
-spec inc_gauge(Gauge, Value) -> ok | {error, not_found}.
```

#### `instrument_metric:dec_gauge/1`, `instrument_metric:dec_gauge/2`

Decrements the gauge.

```erlang
-spec dec_gauge(Gauge) -> ok | {error, not_found}.
-spec dec_gauge(Gauge, Value) -> ok | {error, not_found}.
```

#### `instrument_metric:set_gauge_to_current_time/1`

Sets the gauge to the current Unix timestamp.

```erlang
-spec set_gauge_to_current_time(Gauge) -> ok | {error, not_found}.
```

#### `instrument_metric:get_gauge/1`

Returns the current gauge value.

```erlang
-spec get_gauge(Gauge) -> float() | {error, not_found}.
```

### Histograms

Histograms track the distribution of values.

#### `instrument_metric:new_histogram/2`

Creates a histogram with default buckets.

```erlang
-spec new_histogram(Name, Help) -> Histogram when
    Name :: metric_name(),
    Help :: binary() | string(),
    Histogram :: metric().
```

Default buckets: `[0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1.0, 2.5, 5.0, 7.5, 10.0]`

#### `instrument_metric:new_histogram/3`

Creates a histogram with custom buckets.

```erlang
-spec new_histogram(Name, Help, Buckets) -> Histogram when
    Name :: metric_name(),
    Help :: binary() | string(),
    Buckets :: [number()],
    Histogram :: metric().
```

**Example:**

```erlang
Hist = instrument_metric:new_histogram(
    response_size_bytes,
    <<"Response size">>,
    [100, 500, 1000, 5000, 10000]
).
```

#### `instrument_metric:observe_histogram/2`

Records an observation in the histogram.

```erlang
-spec observe_histogram(Histogram, Value) -> ok | {error, not_found} when
    Histogram :: metric(),
    Value :: number().
```

#### `instrument_metric:get_histogram/1`

Returns histogram data.

```erlang
-spec get_histogram(Histogram) -> #{
    count := non_neg_integer(),
    sum := float(),
    buckets := [{float(), non_neg_integer()}]
} | {error, not_found}.
```

### Vector Metrics (Labeled)

Vector metrics add label dimensions.

#### `instrument_metric:new_counter_vec/3`

Creates a labeled counter.

```erlang
-spec new_counter_vec(Name, Help, Labels) -> ok when
    Name :: metric_name(),
    Help :: binary() | string(),
    Labels :: [atom() | binary() | string()].
```

**Example:**

```erlang
instrument_metric:new_counter_vec(http_requests_total, <<"HTTP requests">>, [method, status]).
```

#### `instrument_metric:new_gauge_vec/3`

Creates a labeled gauge.

```erlang
-spec new_gauge_vec(Name, Help, Labels) -> ok.
```

#### `instrument_metric:new_histogram_vec/3`, `instrument_metric:new_histogram_vec/4`

Creates a labeled histogram.

```erlang
-spec new_histogram_vec(Name, Help, Labels) -> ok.
-spec new_histogram_vec(Name, Help, Labels, Buckets) -> ok.
```

#### Vec Operations

```erlang
%% Counter operations
instrument_metric:inc_counter_vec(Name, LabelValues).
instrument_metric:inc_counter_vec(Name, LabelValues, Value).
instrument_metric:get_counter_vec(Name, LabelValues).

%% Gauge operations
instrument_metric:set_gauge_vec(Name, LabelValues, Value).
instrument_metric:inc_gauge_vec(Name, LabelValues).
instrument_metric:inc_gauge_vec(Name, LabelValues, Value).
instrument_metric:dec_gauge_vec(Name, LabelValues).
instrument_metric:dec_gauge_vec(Name, LabelValues, Value).
instrument_metric:get_gauge_vec(Name, LabelValues).

%% Histogram operations
instrument_metric:observe_histogram_vec(Name, LabelValues, Value).
instrument_metric:get_histogram_vec(Name, LabelValues).
```

**Example:**

```erlang
instrument_metric:inc_counter_vec(http_requests_total, [<<"GET">>, <<"200">>]).
instrument_metric:inc_counter_vec(http_requests_total, [<<"POST">>, <<"201">>], 5).
```

#### `instrument_metric:labels/2`

Returns a metric reference for specific label values.

```erlang
-spec labels(Name, LabelValues) -> metric() | {error, term()}.
```

**Example:**

```erlang
Metric = instrument_metric:labels(http_requests_total, [<<"GET">>, <<"200">>]),
instrument_metric:inc_counter(Metric).
```

#### `instrument_metric:remove_label/2`

Removes a specific label combination.

```erlang
-spec remove_label(Name, LabelValues) -> ok | {error, not_found}.
```

#### `instrument_metric:clear_labels/1`

Removes all label combinations for a metric.

```erlang
-spec clear_labels(Name) -> ok.
```

### Registry

#### `instrument_metric:register/1`

Registers a metric with the global registry.

```erlang
-spec register(Metric) -> ok.
```

#### `instrument_metric:unregister/1`

Unregisters a metric by name.

```erlang
-spec unregister(Name) -> ok | {error, not_found}.
```

#### `instrument_metric:unregister_all/0`

Unregisters all metrics.

```erlang
-spec unregister_all() -> ok.
```

## OTel API

The `instrument_meter` module provides an OpenTelemetry-compatible API.

### MeterProvider

#### `instrument_meter:get_meter/1`, `instrument_meter:get_meter/2`

Gets or creates a meter.

```erlang
-spec get_meter(Name) -> meter().
-spec get_meter(Name, Opts) -> meter() when
    Opts :: #{
        version => binary(),
        schema_url => binary(),
        resource => map()
    }.
```

**Example:**

```erlang
Meter = instrument_meter:get_meter(<<"my_service">>).
Meter = instrument_meter:get_meter(<<"my_service">>, #{version => <<"1.0.0">>}).
```

### Creating Instruments

#### `instrument_meter:create_counter/2`, `instrument_meter:create_counter/3`

Creates a counter instrument.

```erlang
-spec create_counter(Meter, Name) -> instrument().
-spec create_counter(Meter, Name, Opts) -> instrument() when
    Opts :: #{
        description => binary(),
        unit => binary()
    }.
```

#### `instrument_meter:create_up_down_counter/2`, `instrument_meter:create_up_down_counter/3`

Creates an up-down counter (can increase and decrease).

```erlang
-spec create_up_down_counter(Meter, Name) -> instrument().
-spec create_up_down_counter(Meter, Name, Opts) -> instrument().
```

#### `instrument_meter:create_histogram/2`, `instrument_meter:create_histogram/3`

Creates a histogram instrument.

```erlang
-spec create_histogram(Meter, Name) -> instrument().
-spec create_histogram(Meter, Name, Opts) -> instrument() when
    Opts :: #{
        description => binary(),
        unit => binary(),
        boundaries => [number()]
    }.
```

#### `instrument_meter:create_gauge/2`, `instrument_meter:create_gauge/3`

Creates a gauge instrument.

```erlang
-spec create_gauge(Meter, Name) -> instrument().
-spec create_gauge(Meter, Name, Opts) -> instrument().
```

#### Observable Instruments

```erlang
%% Observable counter (read-only, callback-based)
instrument_meter:create_observable_counter(Meter, Name, Callback).

%% Observable gauge
instrument_meter:create_observable_gauge(Meter, Name, Callback).

%% Observable up-down counter
instrument_meter:create_observable_up_down_counter(Meter, Name, Callback).
```

**Example:**

```erlang
instrument_meter:create_observable_gauge(Meter, <<"memory_usage">>, fun() ->
    erlang:memory(total)
end).
```

### Recording Values

#### `instrument_meter:add/2`, `instrument_meter:add/3`

Adds a value to a counter or up-down counter.

```erlang
-spec add(Instrument, Value) -> ok.
-spec add(Instrument, Value, Attributes) -> ok when
    Attributes :: map().
```

**Example:**

```erlang
instrument_meter:add(Counter, 1).
instrument_meter:add(Counter, 1, #{method => <<"GET">>, status => 200}).
```

#### `instrument_meter:record/2`, `instrument_meter:record/3`

Records a value in a histogram.

```erlang
-spec record(Instrument, Value) -> ok.
-spec record(Instrument, Value, Attributes) -> ok.
```

#### `instrument_meter:set/2`, `instrument_meter:set/3`

Sets a gauge value.

```erlang
-spec set(Instrument, Value) -> ok.
-spec set(Instrument, Value, Attributes) -> ok.
```

### Utility

```erlang
%% Get instrument by name
instrument_meter:get_instrument(Name).

%% List all instruments
instrument_meter:list_instruments().

%% Trigger observable callbacks
instrument_meter:collect_observables().

%% Cleanup
instrument_meter:unregister_instrument(Name).
instrument_meter:unregister_all_instruments().
```

## Types

```erlang
-type metric_name() :: atom() | binary() | string().
-type metric() :: #metric{} | atom().
-type metric_type() :: counter | gauge | histogram.
-type label() :: atom() | binary() | string().
-type labels() :: [label()].

-type meter() :: #meter{}.
-type instrument() :: #otel_instrument{}.
-type instrument_opts() :: #{
    description => binary(),
    unit => binary(),
    boundaries => [number()]
}.
```

## Prometheus Export

The `instrument_prometheus` module formats metrics for Prometheus.

```erlang
%% Get Prometheus text format
Body = instrument_prometheus:format().

%% Get content type header
ContentType = instrument_prometheus:content_type().
%% Returns: <<"text/plain; version=0.0.4; charset=utf-8">>
```

## Best Practices

### Naming Conventions

- Use `snake_case` for metric names
- Include unit in name: `_seconds`, `_bytes`, `_total`
- Counter names should end with `_total`
- Use descriptive names: `http_requests_total` not `requests`

### Labels

- Keep cardinality bounded (< 100 unique combinations)
- Don't use high-cardinality values (user IDs, request IDs)
- Use consistent label names across metrics
- Order label values consistently

### Performance

- Create metrics at startup, not per-request
- Use `labels/2` for repeated updates to same label combination
- Monitor cardinality growth
- Consider sampling for high-frequency metrics
