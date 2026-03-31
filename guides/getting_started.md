# Getting Started with Instrument

This guide will help you get started with the instrument library for metrics and tracing in your Erlang application.

## Installation

### rebar3

Add instrument to your `rebar.config`:

```erlang
{deps, [
    {instrument, "0.3.0"}
]}.
```

### mix (Elixir)

```elixir
{:instrument, "~> 0.3.0"}
```

## Starting the Application

Instrument starts automatically when included as a dependency. You can also start it manually:

```erlang
application:start(instrument).
```

## Your First Metrics

### Counter

Counters track cumulative values that only increase (e.g., total requests):

```erlang
%% Create a counter
Counter = instrument:new_counter(http_requests_total, "Total HTTP requests"),

%% Increment by 1
instrument:inc_counter(Counter),

%% Increment by a specific value
instrument:inc_counter(Counter, 10),

%% Get current value
Value = instrument:get_counter(Counter).  %% Returns 11.0
```

### Gauge

Gauges track values that can go up or down (e.g., current connections):

```erlang
%% Create a gauge
Gauge = instrument:new_gauge(active_connections, "Current active connections"),

%% Set to a specific value
instrument:set_gauge(Gauge, 100),

%% Increment/decrement
instrument:inc_gauge(Gauge),      %% Now 101
instrument:dec_gauge(Gauge, 5),   %% Now 96

%% Get current value
Value = instrument:get_gauge(Gauge).
```

### Histogram

Histograms track distributions of values (e.g., request latencies):

```erlang
%% Create with default buckets
Histogram = instrument:new_histogram(request_duration_seconds, "Request duration"),

%% Create with custom buckets
Histogram2 = instrument:new_histogram(response_size_bytes, "Response size",
    [100, 500, 1000, 5000, 10000]),

%% Record observations
instrument:observe_histogram(Histogram, 0.125),
instrument:observe_histogram(Histogram, 0.250),

%% Get histogram data
#{count := Count, sum := Sum, buckets := Buckets} = instrument:get_histogram(Histogram).
```

## Labeled Metrics (Vec API)

Add dimensions to your metrics with labels:

```erlang
%% Create a counter with labels
instrument:new_counter_vec(http_requests_total, "HTTP requests", [method, status]),

%% Increment specific label combinations
instrument:inc_counter_vec(http_requests_total, ["GET", "200"]),
instrument:inc_counter_vec(http_requests_total, ["POST", "201"]),
instrument:inc_counter_vec(http_requests_total, ["GET", "404"]),

%% Get value for specific labels
Value = instrument:get_counter_vec(http_requests_total, ["GET", "200"]).
```

## Prometheus Export

Export all metrics in Prometheus text format:

```erlang
%% In your HTTP handler
handle_metrics_request(Req) ->
    Body = instrument_prometheus:format(),
    ContentType = instrument_prometheus:content_type(),
    {200, [{<<"content-type">>, ContentType}], Body}.
```

## Your First Trace

### Basic Span

```erlang
%% Create a span around an operation
instrument_tracer:with_span(<<"process_order">>, fun() ->
    %% Your code here
    Order = fetch_order(OrderId),
    process(Order)
end).
```

### Adding Indexable Attributes to Spans

Attributes are key-value pairs that get indexed by your observability backend, enabling filtering and querying:

```erlang
instrument_tracer:with_span(<<"process_order">>, fun() ->
    %% Add indexable attributes - these can be queried in Jaeger, Tempo, etc.
    instrument_tracer:set_attributes(#{
        %% String attributes
        <<"order.id">> => OrderId,
        <<"customer.id">> => CustomerId,
        <<"customer.tier">> => <<"premium">>,

        %% Numeric attributes (can filter by range)
        <<"order.total">> => 149.99,
        <<"order.item_count">> => 5,

        %% Boolean attributes
        <<"order.express">> => true
    }),

    %% Add timestamped events
    instrument_tracer:add_event(<<"order_validated">>),

    Result = process_order(Order),

    %% Set status
    instrument_tracer:set_status(ok),
    Result
end).
```

Now you can query traces in your backend:
- Find all orders from premium customers: `customer.tier = "premium"`
- Find expensive orders: `order.total > 100`
- Find failed express orders: `order.express = true AND status = error`

### Nested Spans

```erlang
instrument_tracer:with_span(<<"handle_request">>, fun() ->
    %% Child span automatically linked to parent
    instrument_tracer:with_span(<<"validate_input">>, fun() ->
        validate(Input)
    end),

    instrument_tracer:with_span(<<"process_data">>, fun() ->
        process(Data)
    end),

    instrument_tracer:with_span(<<"send_response">>, fun() ->
        send(Response)
    end)
end).
```

## Logger Integration

Automatically add trace context to your logs:

```erlang
%% Install the logger integration (typically in your app start)
instrument_logger:install(),

%% Now all logs within spans include trace_id and span_id
instrument_tracer:with_span(<<"my_operation">>, fun() ->
    logger:info("Processing request"),  %% Includes trace context
    do_work()
end).
```

## Next Steps

- Read the [Instrumentation Guide](instrumentation_guide.md) for best practices
- Learn about [Context Propagation](context_propagation.md) for distributed tracing
