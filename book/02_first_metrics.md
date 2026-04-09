# Your First Metrics

This chapter introduces the three fundamental metric types: counters, gauges, and histograms.

## Setting Up

First, add `instrument` to your project and start the application:

```erlang
%% In rebar.config
{deps, [
    {instrument, "0.3.0"}
]}.

%% In your code or shell
application:ensure_all_started(instrument).
```

## Counters

A counter is a value that only goes up. Use counters when you want to count events.

### Creating a Counter

```erlang
Counter = instrument_metric:new_counter(http_requests_total, <<"Total HTTP requests">>).
```

The arguments are:
- `http_requests_total` - the metric name (atom, string, or binary)
- `<<"Total HTTP requests">>` - a description for documentation

### Using a Counter

```erlang
%% Increment by 1
instrument_metric:inc_counter(Counter).

%% Increment by a specific amount
instrument_metric:inc_counter(Counter, 5).

%% Read the current value
Value = instrument_metric:get_counter(Counter).  %% Returns 6.0
```

### When to Use Counters

Counters are ideal for:
- Request counts
- Error counts
- Bytes sent/received
- Tasks completed
- Messages processed

### Counter Best Practices

**Do:**
- Use `_total` suffix for counters
- Count things that complete, not things that start
- Reset counters only at process restart

**Don't:**
- Use counters for values that can decrease
- Decrement counters (use gauges instead)

## Gauges

A gauge is a value that can go up or down. Use gauges for current state.

### Creating a Gauge

```erlang
Gauge = instrument_metric:new_gauge(active_connections, <<"Current active connections">>).
```

### Using a Gauge

```erlang
%% Set to a specific value
instrument_metric:set_gauge(Gauge, 100).

%% Increment by 1
instrument_metric:inc_gauge(Gauge).  %% Now 101

%% Decrement
instrument_metric:dec_gauge(Gauge).        %% Now 100
instrument_metric:dec_gauge(Gauge, 10).    %% Now 90

%% Set to current time
instrument_metric:set_gauge_to_current_time(Gauge).

%% Read the value
Value = instrument_metric:get_gauge(Gauge).
```

### When to Use Gauges

Gauges are ideal for:
- Connection pool sizes
- Queue lengths
- Memory usage
- Temperature readings
- Cache sizes

### Gauge Best Practices

**Do:**
- Use gauges for "current" values
- Update gauges when state changes
- Consider using observable gauges for expensive computations

**Don't:**
- Use gauges for cumulative totals (use counters)
- Forget to decrement when connections close

## Histograms

A histogram tracks the distribution of values. Use histograms for latencies and sizes.

### Creating a Histogram

```erlang
%% With default buckets
Histogram = instrument_metric:new_histogram(
    request_duration_seconds,
    <<"Request duration in seconds">>
).

%% With custom buckets
Histogram2 = instrument_metric:new_histogram(
    response_size_bytes,
    <<"Response size in bytes">>,
    [100, 500, 1000, 5000, 10000]
).
```

### Using a Histogram

```erlang
%% Record an observation
instrument_metric:observe_histogram(Histogram, 0.125).
instrument_metric:observe_histogram(Histogram, 0.250).
instrument_metric:observe_histogram(Histogram, 0.050).

%% Get the distribution
#{
    count := Count,
    sum := Sum,
    buckets := Buckets
} = instrument_metric:get_histogram(Histogram).
```

### Understanding Buckets

Buckets define the boundaries for counting observations:

```erlang
%% Default buckets
[0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1.0, 2.5, 5.0, 7.5, 10.0]
```

Each bucket counts observations less than or equal to its value. The histogram data includes:
- `count`: Total number of observations
- `sum`: Sum of all observed values
- `buckets`: List of `{Boundary, Count}` pairs

### When to Use Histograms

Histograms are ideal for:
- Request latencies
- Response sizes
- Batch sizes
- Queue wait times

### Histogram Best Practices

**Do:**
- Use `_seconds` suffix for durations
- Use `_bytes` suffix for sizes
- Choose buckets that match your SLOs
- Observe all requests, including errors

**Don't:**
- Create too many buckets (10-15 is usually enough)
- Use histograms for counts (use counters)

## Putting It Together

Here is a complete example instrumenting an HTTP handler:

```erlang
-module(my_handler).
-export([init/0, handle/2]).

init() ->
    %% Create metrics at startup
    instrument_metric:new_counter(http_requests_total, <<"Total HTTP requests">>),
    instrument_metric:new_gauge(http_active_requests, <<"Active HTTP requests">>),
    instrument_metric:new_histogram(http_request_duration_seconds, <<"Request duration">>).

handle(Method, Path) ->
    %% Track active requests
    instrument_metric:inc_gauge(http_active_requests),

    %% Time the request
    Start = erlang:monotonic_time(microsecond),

    try
        Result = do_handle(Method, Path),

        %% Count successful request
        instrument_metric:inc_counter(http_requests_total),
        Result
    after
        %% Always record duration and decrement active
        Duration = (erlang:monotonic_time(microsecond) - Start) / 1000000,
        instrument_metric:observe_histogram(http_request_duration_seconds, Duration),
        instrument_metric:dec_gauge(http_active_requests)
    end.
```

## Exercise

Instrument a simple cache module:

1. Create a counter for cache hits
2. Create a counter for cache misses
3. Create a gauge for cache size
4. Create a histogram for lookup latencies

Test your instrumentation in the shell.

## Next Steps

Your metrics now track individual values. In the next chapter, you will learn how to add dimensions using labels.
