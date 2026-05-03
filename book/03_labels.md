# Adding Dimensions with Labels

Plain metrics answer simple questions. Labels make those questions more useful by letting you break the data down by dimensions such as method, status, endpoint, pool, or operation.

## The Problem

A counter can tell you there were 1,000 requests. In practice, that is rarely enough. You usually also need to know:

- How many were GET vs POST?
- How many returned 200 vs 500?
- Which endpoints are busiest?

Labels add those dimensions without forcing you to create a separate metric for every case.

## The Vec API

The "Vec" (vector) API creates metrics that carry label dimensions:

```erlang
%% Create a counter with labels
instrument_metric:new_counter_vec(
    http_requests_total,
    <<"HTTP requests by method and status">>,
    [method, status]
).
```

The third argument is the list of label names. Every measurement then provides values for those labels, in the same order.

## Using Labeled Metrics

### Counters with Labels

```erlang
%% Create the metric once
instrument_metric:new_counter_vec(http_requests_total, <<"HTTP requests">>, [method, status]).

%% Record with label values
instrument_metric:inc_counter_vec(http_requests_total, [<<"GET">>, <<"200">>]).
instrument_metric:inc_counter_vec(http_requests_total, [<<"POST">>, <<"201">>]).
instrument_metric:inc_counter_vec(http_requests_total, [<<"GET">>, <<"404">>]).

%% Increment by more than 1
instrument_metric:inc_counter_vec(http_requests_total, [<<"GET">>, <<"200">>], 5).

%% Get a specific combination
Value = instrument_metric:get_counter_vec(http_requests_total, [<<"GET">>, <<"200">>]).
```

### Gauges with Labels

```erlang
instrument_metric:new_gauge_vec(connection_pool_size, <<"Pool connections">>, [pool, state]).

%% Track different pools and states
instrument_metric:set_gauge_vec(connection_pool_size, [<<"default">>, <<"active">>], 10).
instrument_metric:set_gauge_vec(connection_pool_size, [<<"default">>, <<"idle">>], 5).
instrument_metric:set_gauge_vec(connection_pool_size, [<<"secondary">>, <<"active">>], 3).
```

### Histograms with Labels

```erlang
instrument_metric:new_histogram_vec(
    db_query_duration_seconds,
    <<"Database query duration">>,
    [operation]
).

%% Record by operation type
instrument_metric:observe_histogram_vec(db_query_duration_seconds, [<<"SELECT">>], 0.05).
instrument_metric:observe_histogram_vec(db_query_duration_seconds, [<<"INSERT">>], 0.02).
instrument_metric:observe_histogram_vec(db_query_duration_seconds, [<<"UPDATE">>], 0.08).
```

## The labels/2 Function

If you update the same label combination repeatedly, get a handle for it once:

```erlang
%% Get a metric handle for specific labels
Metric = instrument_metric:labels(http_requests_total, [<<"GET">>, <<"200">>]).

%% Use like a regular metric
instrument_metric:inc_counter(Metric).
instrument_metric:inc_counter(Metric, 5).
```

That avoids repeating the label lookup on every update.

## Cardinality: The Hidden Cost

Every unique combination of label values creates a new time series. This is called cardinality, and it is the main cost of labeled metrics.

```erlang
%% Labels: method (3 values) x status (5 values) = 15 combinations
instrument_metric:new_counter_vec(http_requests_total, <<"">>, [method, status]).

%% Labels: method x status x user_id = potentially millions!
%% DON'T DO THIS
instrument_metric:new_counter_vec(http_requests_total, <<"">>, [method, status, user_id]).
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
instrument_metric:inc_counter_vec(requests, [<<"/users/123">>]).
instrument_metric:inc_counter_vec(requests, [<<"/users/456">>]).

%% GOOD: Use the route pattern instead
instrument_metric:inc_counter_vec(requests, [<<"/users/{id}">>]).
```

## Removing Labels

You can remove specific label combinations, or clear all values for a metric:

```erlang
%% Remove a specific combination
instrument_metric:remove_label(http_requests_total, [<<"DELETE">>, <<"200">>]).

%% Clear all label combinations (keeps the metric definition)
instrument_metric:clear_labels(http_requests_total).
```

This is useful when you need to:
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

The OTel API uses maps for attributes instead of ordered lists of label values. That is easier to read at call sites, especially when a metric has several dimensions.

## Practical Example

Here is a connection pool example with labels for the pool name, operation, and connection state:

```erlang
-module(pool_metrics).
-export([init/0, checkout/1, checkin/1, timeout/1]).

init() ->
    instrument_metric:new_counter_vec(pool_operations_total, <<"Pool operations">>,
        [pool, operation]),
    instrument_metric:new_gauge_vec(pool_connections, <<"Pool connection state">>,
        [pool, state]),
    instrument_metric:new_histogram_vec(pool_wait_seconds, <<"Pool wait time">>,
        [pool]).

checkout(Pool) ->
    PoolName = atom_to_binary(Pool),
    Start = erlang:monotonic_time(microsecond),

    Result = do_checkout(Pool),

    Duration = (erlang:monotonic_time(microsecond) - Start) / 1000000,
    instrument_metric:observe_histogram_vec(pool_wait_seconds, [PoolName], Duration),

    case Result of
        {ok, Conn} ->
            instrument_metric:inc_counter_vec(pool_operations_total, [PoolName, <<"checkout">>]),
            instrument_metric:inc_gauge_vec(pool_connections, [PoolName, <<"active">>]),
            instrument_metric:dec_gauge_vec(pool_connections, [PoolName, <<"idle">>]),
            {ok, Conn};
        {error, timeout} ->
            instrument_metric:inc_counter_vec(pool_operations_total, [PoolName, <<"timeout">>]),
            {error, timeout}
    end.

checkin(Pool) ->
    PoolName = atom_to_binary(Pool),
    instrument_metric:inc_counter_vec(pool_operations_total, [PoolName, <<"checkin">>]),
    instrument_metric:dec_gauge_vec(pool_connections, [PoolName, <<"active">>]),
    instrument_metric:inc_gauge_vec(pool_connections, [PoolName, <<"idle">>]),
    ok.

timeout(Pool) ->
    PoolName = atom_to_binary(Pool),
    instrument_metric:inc_counter_vec(pool_operations_total, [PoolName, <<"timeout">>]).
```

## Exercise

Extend your cache module from the previous chapter:

1. Add a `cache_name` label to distinguish multiple caches
2. Add an `operation` label (get, set, delete)
3. Track hit rate by cache name

Before you add a label, ask whether its possible values are bounded. A cache name is usually fine. A cache key is not.

## Next Steps

You now know how to create dimensional metrics. Next, we will switch from aggregate behavior to individual requests by introducing traces.
