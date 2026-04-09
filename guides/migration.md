# Migration Guide

How to migrate to `instrument` from other observability libraries.

## Overview

This guide covers migrating from:

- [Folsom](#from-folsom)
- [Exometer](#from-exometer)
- [OpenCensus](#from-opencensus)
- [OpenTelemetry (opentelemetry-erlang)](#from-opentelemetry-erlang)
- [Custom Instrumentation](#from-custom-instrumentation)

## General Migration Strategy

1. **Add instrument alongside existing library**
2. **Migrate metrics one module at a time**
3. **Verify data in both systems**
4. **Remove old library**

## From Folsom

Folsom provides counters, gauges, histograms, and meters.

### Counters

```erlang
%% Folsom
folsom_metrics:new_counter(my_counter),
folsom_metrics:notify({my_counter, {inc, 1}}).

%% instrument
Counter = instrument_metric:new_counter(my_counter, <<"My counter">>),
instrument_metric:inc_counter(Counter).
```

### Gauges

```erlang
%% Folsom
folsom_metrics:new_gauge(my_gauge),
folsom_metrics:notify({my_gauge, 100}).

%% instrument
Gauge = instrument_metric:new_gauge(my_gauge, <<"My gauge">>),
instrument_metric:set_gauge(Gauge, 100).
```

### Histograms

```erlang
%% Folsom
folsom_metrics:new_histogram(my_hist, slide, 60),
folsom_metrics:notify({my_hist, Value}).

%% instrument
Hist = instrument_metric:new_histogram(my_hist, <<"My histogram">>),
instrument_metric:observe_histogram(Hist, Value).
```

### Meters (Rate)

Folsom meters track rates. In `instrument`, calculate rates in your monitoring system:

```erlang
%% Folsom
folsom_metrics:new_meter(requests),
folsom_metrics:notify({requests, 1}).

%% instrument - use counter, Prometheus calculates rate
Counter = instrument_metric:new_counter(requests_total, <<"Total requests">>),
instrument_metric:inc_counter(Counter).

%% In Prometheus: rate(requests_total[5m])
```

### Migration Wrapper

Create a wrapper during migration:

```erlang
-module(metrics).
-export([inc/1, set/2, observe/2]).

inc(Name) ->
    %% Old
    folsom_metrics:notify({Name, {inc, 1}}),
    %% New
    instrument_metric:inc_counter(Name).

set(Name, Value) ->
    folsom_metrics:notify({Name, Value}),
    instrument_metric:set_gauge(Name, Value).

observe(Name, Value) ->
    folsom_metrics:notify({Name, Value}),
    instrument_metric:observe_histogram(Name, Value).
```

## From Exometer

Exometer provides similar primitives with a different API.

### Counters

```erlang
%% Exometer
exometer:new([my, counter], counter),
exometer:update([my, counter], 1).

%% instrument
Counter = instrument_metric:new_counter(my_counter, <<"My counter">>),
instrument_metric:inc_counter(Counter).
```

### Gauges

```erlang
%% Exometer
exometer:new([my, gauge], gauge),
exometer:update([my, gauge], 100).

%% instrument
Gauge = instrument_metric:new_gauge(my_gauge, <<"My gauge">>),
instrument_metric:set_gauge(Gauge, 100).
```

### Histograms

```erlang
%% Exometer
exometer:new([my, hist], histogram),
exometer:update([my, hist], Value).

%% instrument
Hist = instrument_metric:new_histogram(my_hist, <<"My histogram">>),
instrument_metric:observe_histogram(Hist, Value).
```

### Name Conversion

Exometer uses lists for names. Convert to atoms or binaries:

```erlang
exometer_to_instrument_name([A, B, C]) ->
    list_to_atom(lists:flatten(io_lib:format("~s_~s_~s", [A, B, C]))).
```

## From OpenCensus

OpenCensus has similar concepts but different API structure.

### Metrics

```erlang
%% OpenCensus
oc_stat:record([{Tag, Value}], MeasureName, Amount).

%% instrument
instrument_metric:inc_counter_vec(MeasureName, [Value], Amount).
```

### Tracing

```erlang
%% OpenCensus
oc_trace:with_span(Name, fun() ->
    oc_trace:put_attribute(Key, Value),
    work()
end).

%% instrument
instrument_tracer:with_span(Name, fun() ->
    instrument_tracer:set_attribute(Key, Value),
    work()
end).
```

### Context Propagation

```erlang
%% OpenCensus
Headers = oc_propagation_http_tracecontext:to_headers(oc_trace:current_span_ctx()),

%% instrument
Headers = instrument_propagation:inject_headers(instrument_context:current()).
```

## From opentelemetry-erlang

The official OpenTelemetry Erlang SDK. `instrument` provides a compatible API.

### Tracers

```erlang
%% opentelemetry-erlang
Tracer = opentelemetry:get_tracer(my_app),
?with_span(Tracer, <<"operation">>, #{}, fun(_SpanCtx) ->
    ?set_attribute(<<"key">>, <<"value">>),
    work()
end).

%% instrument
instrument_tracer:with_span(<<"operation">>, fun() ->
    instrument_tracer:set_attribute(<<"key">>, <<"value">>),
    work()
end).
```

### Meters

```erlang
%% opentelemetry-erlang
Meter = opentelemetry:get_meter(my_app),
Counter = otel_meter:create_counter(Meter, my_counter, #{}),
otel_counter:add(Counter, 1, #{}).

%% instrument
Meter = instrument_meter:get_meter(<<"my_app">>),
Counter = instrument_meter:create_counter(Meter, <<"my_counter">>, #{}),
instrument_meter:add(Counter, 1, #{}).
```

### Context

```erlang
%% opentelemetry-erlang
otel_ctx:attach(Ctx),
%% ... work ...
otel_ctx:detach(Token).

%% instrument
Token = instrument_context:attach(Ctx),
%% ... work ...
instrument_context:detach(Token).
```

### Propagation

```erlang
%% opentelemetry-erlang
Headers = otel_propagator_text_map:inject([]),

%% instrument
Headers = instrument_propagation:inject_headers(instrument_context:current()).
```

### Migration Notes

- API is largely compatible
- Remove `opentelemetry` from deps
- Update macro calls to function calls
- Context management is similar

## From Custom Instrumentation

### Basic Counters

```erlang
%% Custom (using ets)
ets:update_counter(metrics, my_counter, 1).

%% instrument
instrument_metric:inc_counter(my_counter).
```

### Custom Timing

```erlang
%% Custom
Start = erlang:monotonic_time(),
Result = work(),
End = erlang:monotonic_time(),
Duration = End - Start,
record_timing(my_operation, Duration).

%% instrument
Result = instrument_tracer:with_span(<<"my_operation">>, fun() ->
    work()
end).
%% Duration is recorded automatically
```

### Custom Logging with Request IDs

```erlang
%% Custom
RequestId = generate_request_id(),
logger:info("[~s] Processing request", [RequestId]).

%% instrument
instrument_tracer:with_span(<<"process_request">>, fun() ->
    %% trace_id automatically added to logs
    logger:info("Processing request")
end).
```

## Gradual Migration Pattern

### Phase 1: Dual-Write

```erlang
-module(my_metrics).
-export([inc_counter/1, observe/2]).

inc_counter(Name) ->
    %% Old system
    case application:get_env(my_app, use_old_metrics, true) of
        true -> old_metrics:inc(Name);
        false -> ok
    end,
    %% New system
    case application:get_env(my_app, use_new_metrics, true) of
        true -> instrument_metric:inc_counter(Name);
        false -> ok
    end.
```

### Phase 2: Verify

Compare metrics from both systems to ensure consistency.

### Phase 3: Switch

```erlang
%% config/sys.config
{my_app, [
    {use_old_metrics, false},
    {use_new_metrics, true}
]}.
```

### Phase 4: Remove

Remove old metrics library from deps and code.

## Common Migration Issues

### Name Differences

Create a mapping:

```erlang
migrate_name(old_counter_name) -> new_counter_total;
migrate_name(old_gauge) -> new_gauge;
migrate_name(Other) -> Other.
```

### Label Changes

```erlang
%% Map old tags to new labels
migrate_labels(#{method := M, code := C}) ->
    [M, integer_to_binary(C)];
migrate_labels(#{}) ->
    [].
```

### Histogram Buckets

Ensure bucket boundaries match or data will look different:

```erlang
%% Old buckets
old_buckets() -> [0.1, 0.5, 1.0, 5.0].

%% Match in instrument
instrument_metric:new_histogram(my_hist, <<"">>, [0.1, 0.5, 1.0, 5.0]).
```

### Missing Features

Some features may not have direct equivalents:

| Old Feature | instrument Equivalent |
|-------------|----------------------|
| Spirals | Use counter + rate() in Prometheus |
| Meters | Use counter + rate() |
| Derived | Compute in query language |
| Duration | Use histogram or span duration |

## Verification Checklist

- [ ] All metrics appear in Prometheus
- [ ] Metric values match between old and new
- [ ] Traces appear in Jaeger/backend
- [ ] Logs include trace context
- [ ] Dashboards work with new metric names
- [ ] Alerts fire correctly
- [ ] Performance is acceptable
- [ ] No memory leaks

## Getting Help

If you encounter issues during migration:

1. Check the [API reference guides](./metrics_reference.md)
2. Review [troubleshooting guide](../book/appendix_b_troubleshooting.md)
3. Open an issue on [GitHub](https://github.com/benoitc/instrument/issues)
