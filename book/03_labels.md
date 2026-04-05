# Adding Dimensions with Labels

Plain metrics answer simple questions. Labels let you slice and dice your data by dimensions.

## The Problem

A counter tells you there were 1,000 requests. But you need to know:

- How many were GET vs POST?
- How many returned 200 vs 500?
- Which endpoints are busiest?

Labels add these dimensions to your metrics.

## The Vec API

The "Vec" (vector) API creates metrics with label dimensions:

```erlang
%% Create a counter with labels
instrument:new_counter_vec(
    http_requests_total,
    <<"HTTP requests by method and status">>,
    [method, status]
).
```

The third argument is a list of label names. Each measurement includes values for these labels.

## Using Labeled Metrics

### Counters with Labels

```erlang
%% Create the metric once
instrument:new_counter_vec(http_requests_total, <<"HTTP requests">>, [method, status]).

%% Record with label values
instrument:inc_counter_vec(http_requests_total, [<<"GET">>, <<"200">>]).
instrument:inc_counter_vec(http_requests_total, [<<"POST">>, <<"201">>]).
instrument:inc_counter_vec(http_requests_total, [<<"GET">>, <<"404">>]).

%% Increment by more than 1
instrument:inc_counter_vec(http_requests_total, [<<"GET">>, <<"200">>], 5).

%% Get a specific combination
Value = instrument:get_counter_vec(http_requests_total, [<<"GET">>, <<"200">>]).
```

### Gauges with Labels

```erlang
instrument:new_gauge_vec(connection_pool_size, <<"Pool connections">>, [pool, state]).

%% Track different pools and states
instrument:set_gauge_vec(connection_pool_size, [<<"default">>, <<"active">>], 10).
instrument:set_gauge_vec(connection_pool_size, [<<"default">>, <<"idle">>], 5).
instrument:set_gauge_vec(connection_pool_size, [<<"secondary">>, <<"active">>], 3).
```

### Histograms with Labels

```erlang
instrument:new_histogram_vec(
    db_query_duration_seconds,
    <<"Database query duration">>,
    [operation]
).

%% Record by operation type
instrument:observe_histogram_vec(db_query_duration_seconds, [<<"SELECT">>], 0.05).
instrument:observe_histogram_vec(db_query_duration_seconds, [<<"INSERT">>], 0.02).
instrument:observe_histogram_vec(db_query_duration_seconds, [<<"UPDATE">>], 0.08).
```

## The labels/2 Function

For repeated operations, get a reference to a specific label combination:

```erlang
%% Get a metric handle for specific labels
Metric = instrument:labels(http_requests_total, [<<"GET">>, <<"200">>]).

%% Use like a regular metric
instrument:inc_counter(Metric).
instrument:inc_counter(Metric, 5).
```

This is more efficient when you will update the same combination multiple times.

## Cardinality: The Hidden Cost

Every unique combination of label values creates a new time series. This is called cardinality.

```erlang
%% Labels: method (3 values) x status (5 values) = 15 combinations
instrument:new_counter_vec(http_requests_total, <<"">>, [method, status]).

%% Labels: method x status x user_id = potentially millions!
%% DON'T DO THIS
instrument:new_counter_vec(http_requests_total, <<"">>, [method, status, user_id]).
```

### High Cardinality Labels to Avoid

**Never use these as labels:**
- User IDs
- Request IDs
- Session IDs
- Timestamps
- Email addresses
- IP addresses (unless you have very few)

**Safe label values:**
- HTTP methods (GET, POST, PUT, DELETE)
- Status code categories (2xx, 4xx, 5xx)
- Endpoint names
- Service names
- Boolean flags

### Managing Cardinality

```erlang
%% BAD: Creates a series for every endpoint path
instrument:inc_counter_vec(requests, [<<"/users/123">>]).
instrument:inc_counter_vec(requests, [<<"/users/456">>]).

%% GOOD: Use the route pattern instead
instrument:inc_counter_vec(requests, [<<"/users/{id}">>]).
```

## Removing Labels

You can remove specific label combinations or clear all:

```erlang
%% Remove a specific combination
instrument:remove_label(http_requests_total, [<<"DELETE">>, <<"200">>]).

%% Clear all label combinations (keeps the metric definition)
instrument:clear_labels(http_requests_total).
```

This is useful for:
- Cleaning up after tests
- Removing discontinued endpoints
- Managing memory in long-running systems

## OpenTelemetry Style API

The `instrument_meter` module provides an OTel-compatible API with attributes:

```erlang
%% Create a meter
Meter = instrument_meter:get_meter(<<"my_service">>).

%% Create instruments
Counter = instrument_meter:create_counter(Meter, <<"http_requests_total">>, #{
    description => <<"Total HTTP requests">>,
    unit => <<"1">>
}).

%% Record with attributes (like labels)
instrument_meter:add(Counter, 1, #{method => <<"GET">>, status => 200}).
instrument_meter:add(Counter, 1, #{method => <<"POST">>, status => 201}).
```

The OTel API uses maps for attributes instead of ordered lists for labels.

## Practical Example

Instrument a connection pool:

```erlang
-module(pool_metrics).
-export([init/0, checkout/1, checkin/1, timeout/1]).

init() ->
    instrument:new_counter_vec(pool_operations_total, <<"Pool operations">>,
        [pool, operation]),
    instrument:new_gauge_vec(pool_connections, <<"Pool connection state">>,
        [pool, state]),
    instrument:new_histogram_vec(pool_wait_seconds, <<"Pool wait time">>,
        [pool]).

checkout(Pool) ->
    PoolName = atom_to_binary(Pool),
    Start = erlang:monotonic_time(microsecond),

    Result = do_checkout(Pool),

    Duration = (erlang:monotonic_time(microsecond) - Start) / 1000000,
    instrument:observe_histogram_vec(pool_wait_seconds, [PoolName], Duration),

    case Result of
        {ok, Conn} ->
            instrument:inc_counter_vec(pool_operations_total, [PoolName, <<"checkout">>]),
            instrument:inc_gauge_vec(pool_connections, [PoolName, <<"active">>]),
            instrument:dec_gauge_vec(pool_connections, [PoolName, <<"idle">>]),
            {ok, Conn};
        {error, timeout} ->
            instrument:inc_counter_vec(pool_operations_total, [PoolName, <<"timeout">>]),
            {error, timeout}
    end.

checkin(Pool) ->
    PoolName = atom_to_binary(Pool),
    instrument:inc_counter_vec(pool_operations_total, [PoolName, <<"checkin">>]),
    instrument:dec_gauge_vec(pool_connections, [PoolName, <<"active">>]),
    instrument:inc_gauge_vec(pool_connections, [PoolName, <<"idle">>]),
    ok.

timeout(Pool) ->
    PoolName = atom_to_binary(Pool),
    instrument:inc_counter_vec(pool_operations_total, [PoolName, <<"timeout">>]).
```

## Exercise

Extend your cache module from the previous chapter:

1. Add a `cache_name` label to distinguish multiple caches
2. Add an `operation` label (get, set, delete)
3. Track hit rate by cache name

Consider: What labels would cause cardinality problems?

## Next Steps

You now know how to create dimensional metrics. In the next chapter, you will learn about distributed tracing and how traces complement metrics.
