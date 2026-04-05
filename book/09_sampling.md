# Sampling for Scale

At scale, collecting every span is expensive. Sampling lets you control costs while maintaining visibility.

## Why Sample?

Consider:
- 1,000 requests/second
- 10 spans per request
- 10,000 spans/second

That's a lot of data to store and analyze. Sampling collects a representative subset.

## Sampling Basics

A sampler decides whether to record each trace:

- **Sampled**: Span is recorded and exported
- **Not sampled**: Span is dropped (but trace context is still propagated)

The sampling decision is made at trace start and propagates to all spans in the trace.

## Built-in Samplers

### Always On

Records every trace. Use for development or low-traffic services.

```erlang
os:putenv("OTEL_TRACES_SAMPLER", "always_on"),
instrument_config:init().
```

### Always Off

Records no traces. Use to disable tracing completely.

```erlang
os:putenv("OTEL_TRACES_SAMPLER", "always_off"),
instrument_config:init().
```

### Probability (TraceIdRatio)

Records a percentage of traces. Use for high-traffic services.

```erlang
%% Sample 10% of traces
os:putenv("OTEL_TRACES_SAMPLER", "traceidratio"),
os:putenv("OTEL_TRACES_SAMPLER_ARG", "0.1"),
instrument_config:init().
```

The ratio is a decimal between 0.0 and 1.0:
- `0.1` = 10% of traces
- `0.01` = 1% of traces
- `1.0` = 100% of traces

### Parent-Based Samplers

Respect the parent's sampling decision. This keeps traces complete.

```erlang
%% Default: parent-based with always_on root
os:putenv("OTEL_TRACES_SAMPLER", "parentbased_always_on").

%% Parent-based with probability for root spans
os:putenv("OTEL_TRACES_SAMPLER", "parentbased_traceidratio"),
os:putenv("OTEL_TRACES_SAMPLER_ARG", "0.1").
```

Parent-based sampling:
- If parent is sampled: sample this span
- If parent is not sampled: don't sample
- If no parent (root): apply the configured sampler

## Programmatic Configuration

Configure samplers in code:

```erlang
%% Always on
instrument_sampler:set_sampler({instrument_sampler_always_on, #{}}).

%% Always off
instrument_sampler:set_sampler({instrument_sampler_always_off, #{}}).

%% Probability
instrument_sampler:set_sampler({instrument_sampler_probability, #{ratio => 0.1}}).

%% Parent-based
instrument_sampler:set_sampler({instrument_sampler_parent_based, #{
    root => {instrument_sampler_probability, #{ratio => 0.1}},
    remote_parent_sampled => {instrument_sampler_always_on, #{}},
    remote_parent_not_sampled => {instrument_sampler_always_off, #{}},
    local_parent_sampled => {instrument_sampler_always_on, #{}},
    local_parent_not_sampled => {instrument_sampler_always_off, #{}}
}}).
```

## Custom Samplers

For complex requirements, implement a custom sampler:

```erlang
-module(my_sampler).
-behaviour(instrument_sampler).
-export([should_sample/6]).

should_sample(TraceId, SpanName, SpanKind, Attributes, Links, ParentCtx) ->
    %% Sample all errors
    case maps:get(<<"error">>, Attributes, false) of
        true ->
            #sampling_result{
                decision = record_and_sample,
                attributes = #{},
                trace_state = []
            };
        false ->
            %% Sample 10% of normal requests
            case rand:uniform() < 0.1 of
                true ->
                    #sampling_result{decision = record_and_sample};
                false ->
                    #sampling_result{decision = drop}
            end
    end.
```

Use your custom sampler:

```erlang
instrument_sampler:set_sampler({my_sampler, #{}}).
```

## Sampling Decisions

A sampling decision can be:

| Decision | Recording | Exported |
|----------|-----------|----------|
| `record_and_sample` | Yes | Yes |
| `record_only` | Yes | No |
| `drop` | No | No |

Use `record_only` when you want to process spans locally but not export them.

## Checking Sampling Status

In your code, check if the current span is sampled:

```erlang
%% Check if being recorded
case instrument_tracer:is_recording() of
    true ->
        %% Span is being recorded, expensive attributes are worth it
        instrument_tracer:set_attributes(expensive_to_compute());
    false ->
        ok
end.

%% Check if sampled for export
IsSampled = instrument_tracer:is_sampled().
```

## Sampling Strategies

### Head-based Sampling

Decision made at trace start. All spans in the trace follow the same decision.

**Pros:**
- Simple to implement
- Consistent (whole trace or nothing)
- Low overhead

**Cons:**
- Can't sample based on outcome
- May miss interesting traces

### Tail-based Sampling (External)

Decision made after trace completes. Requires a collector.

**Pros:**
- Can sample based on errors, latency, etc.
- Keeps interesting traces

**Cons:**
- Higher complexity
- Requires buffering
- Higher resource usage

The `instrument` library uses head-based sampling. For tail-based sampling, use an OpenTelemetry Collector.

## Production Recommendations

### Low Traffic (< 100 req/s)

```erlang
%% Sample everything
os:putenv("OTEL_TRACES_SAMPLER", "always_on").
```

### Medium Traffic (100-1000 req/s)

```erlang
%% Sample 50%
os:putenv("OTEL_TRACES_SAMPLER", "parentbased_traceidratio"),
os:putenv("OTEL_TRACES_SAMPLER_ARG", "0.5").
```

### High Traffic (> 1000 req/s)

```erlang
%% Sample 10% or less
os:putenv("OTEL_TRACES_SAMPLER", "parentbased_traceidratio"),
os:putenv("OTEL_TRACES_SAMPLER_ARG", "0.1").
```

### Mixed Strategy

Use different rates for different operations:

```erlang
-module(my_sampler).
-export([should_sample/6]).

should_sample(_TraceId, SpanName, _Kind, Attrs, _Links, _Parent) ->
    Rate = case SpanName of
        <<"health_check">> -> 0.01;      %% 1% for health checks
        <<"process_order">> -> 0.5;       %% 50% for orders
        <<"critical_", _/binary>> -> 1.0; %% 100% for critical ops
        _ -> 0.1                           %% 10% default
    end,

    case rand:uniform() < Rate of
        true -> #sampling_result{decision = record_and_sample};
        false -> #sampling_result{decision = drop}
    end.
```

## Span Processors

Span processors run before export. Use them for filtering or enrichment.

### Simple Processor

Exports spans immediately (synchronously):

```erlang
instrument_span_processor_simple:start_link(#{
    exporter => MyExporter
}).
```

### Batch Processor

Buffers and exports in batches (asynchronously):

```erlang
instrument_span_processor_batch:start_link(#{
    exporter => MyExporter,
    max_queue_size => 2048,
    scheduled_delay => 5000,
    max_export_batch_size => 512
}).
```

## Exercise

1. Measure trace volume with always_on sampling
2. Calculate an appropriate sampling rate
3. Configure probability sampling
4. Verify traces are still representative

Questions to answer:
- How many traces per minute with 100% sampling?
- What rate keeps it under 1000 traces/minute?
- Do error traces still appear in samples?

## Next Steps

You now understand how to control costs with sampling. In the final chapter, you will build a complete instrumented service.
