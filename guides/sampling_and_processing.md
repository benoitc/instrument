# Sampling and Processing Guide

This guide covers how to configure sampling (which spans to record) and processing (how to handle and export spans) in the instrument library.

## Table of Contents

1. [Overview](#overview)
2. [Samplers](#samplers)
   - [AlwaysOn Sampler](#alwayson-sampler)
   - [AlwaysOff Sampler](#alwaysoff-sampler)
   - [Probability Sampler](#probability-sampler)
   - [ParentBased Sampler](#parentbased-sampler)
3. [Span Processors](#span-processors)
   - [Simple Processor](#simple-processor)
   - [Batch Processor](#batch-processor)
4. [Complete Pipeline](#complete-pipeline)
5. [Environment Variables](#environment-variables)
6. [Examples](#examples)

## Overview

The tracing pipeline has two key stages:

1. **Sampling** - Decides whether a span should be recorded and exported. This happens at span creation time.
2. **Processing** - Handles recorded spans, typically batching and exporting them to backends.

```
             ┌──────────────┐       ┌─────────────┐       ┌──────────────┐
Span Start ──▶   Sampler    ├──────▶  Processor   ├──────▶   Exporter    │
             │ (drop/record)│       │(batch/export)│       │(OTLP/Console)│
             └──────────────┘       └─────────────┘       └──────────────┘
```

## Samplers

Samplers determine whether spans should be sampled (recorded and exported). The decision is made when a span starts.

### Sampling Decisions

- `drop` - Don't record the span
- `record_only` - Record but don't export
- `record_and_sample` - Record and export

### AlwaysOn Sampler

Samples every span. Default sampler, suitable for development or low-traffic services.

```erlang
instrument_sampler:set_sampler(instrument_sampler_always_on).
```

### AlwaysOff Sampler

Drops all spans. Useful for temporarily disabling tracing.

```erlang
instrument_sampler:set_sampler(instrument_sampler_always_off).
```

### Probability Sampler

Samples a percentage of traces based on trace ID. The decision is deterministic: the same trace ID always produces the same decision, ensuring consistent sampling across services.

```erlang
%% Sample 10% of traces
instrument_sampler:set_sampler(instrument_sampler_probability, #{ratio => 0.1}).

%% Sample 50% of traces
instrument_sampler:set_sampler(instrument_sampler_probability, #{ratio => 0.5}).
```

**Configuration:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `ratio` | `float` | `1.0` | Sampling probability (0.0 to 1.0) |

### ParentBased Sampler

Respects the parent span's sampling decision. Essential for distributed tracing to maintain consistent sampling across services.

- If parent is sampled, child is sampled
- If parent is not sampled, child is not sampled
- If no parent (root span), delegates to a configurable root sampler

```erlang
%% ParentBased with probability sampling for root spans
instrument_sampler:set_sampler(instrument_sampler_parent_based, #{
    root => instrument_sampler_probability,
    root_config => #{ratio => 0.1}
}).

%% ParentBased with always-on for root spans (default behavior)
instrument_sampler:set_sampler(instrument_sampler_parent_based, #{
    root => instrument_sampler_always_on
}).
```

**Configuration:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `root` | `module` | `instrument_sampler_always_on` | Sampler for root spans |
| `root_config` | `map` | `#{}` | Configuration for root sampler |
| `remote_parent_sampled` | `module` | `instrument_sampler_always_on` | Sampler when remote parent is sampled |
| `remote_parent_sampled_config` | `map` | `#{}` | Config for remote sampled |
| `remote_parent_not_sampled` | `module` | `instrument_sampler_always_off` | Sampler when remote parent is not sampled |
| `remote_parent_not_sampled_config` | `map` | `#{}` | Config for remote not sampled |
| `local_parent_sampled` | `module` | `instrument_sampler_always_on` | Sampler when local parent is sampled |
| `local_parent_sampled_config` | `map` | `#{}` | Config for local sampled |
| `local_parent_not_sampled` | `module` | `instrument_sampler_always_off` | Sampler when local parent is not sampled |
| `local_parent_not_sampled_config` | `map` | `#{}` | Config for local not sampled |

## Span Processors

Span processors handle spans after they're created. They receive spans on start and end, and are responsible for batching and exporting.

### Simple Processor

Exports each span immediately when it ends. Suitable for development and debugging.

```erlang
instrument_span_processor:register(instrument_span_processor_simple, #{
    exporter => instrument_exporter_console,
    exporter_config => #{format => text}
}).
```

**Configuration:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `exporter` | `module` | required | Exporter module |
| `exporter_config` | `map` | `#{}` | Configuration for exporter |

**When to use:**
- Development and debugging
- Low-traffic applications
- When you need immediate visibility

### Batch Processor

Queues spans and exports them in batches. Recommended for production use.

```erlang
instrument_span_processor:register(instrument_span_processor_batch, #{
    exporter => instrument_exporter_otlp,
    exporter_config => #{endpoint => "http://localhost:4318"},
    max_queue_size => 2048,
    max_export_batch_size => 512,
    schedule_delay_millis => 5000
}).
```

**Configuration:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `exporter` | `module` | required | Exporter module |
| `exporter_config` | `map` | `#{}` | Configuration for exporter |
| `max_queue_size` | `integer` | `2048` | Max spans in queue before dropping |
| `max_export_batch_size` | `integer` | `512` | Max spans per export batch |
| `schedule_delay_millis` | `integer` | `5000` | Delay between scheduled exports (ms) |
| `export_timeout_millis` | `integer` | `30000` | Export timeout (ms) |

**Behavior:**
- Spans are exported when the batch reaches `max_export_batch_size`
- Or after `schedule_delay_millis` has elapsed
- If queue reaches `max_queue_size`, new spans are dropped

### Managing Processors

```erlang
%% List registered processors
instrument_span_processor:list().
%% [instrument_span_processor_batch]

%% Force flush all pending spans
instrument_span_processor:force_flush().

%% Unregister a processor
instrument_span_processor:unregister(instrument_span_processor_batch).

%% Shutdown all processors
instrument_span_processor:shutdown().
```

## Complete Pipeline

Here's how to set up a complete tracing pipeline:

```erlang
%% 1. Configure sampler (10% sampling with parent-based)
instrument_sampler:set_sampler(instrument_sampler_parent_based, #{
    root => instrument_sampler_probability,
    root_config => #{ratio => 0.1}
}).

%% 2. Register processor with exporter
instrument_span_processor:register(instrument_span_processor_batch, #{
    exporter => instrument_exporter_otlp,
    exporter_config => #{
        endpoint => "http://localhost:4318",
        compression => gzip
    },
    max_queue_size => 4096,
    schedule_delay_millis => 2000
}).

%% 3. Create spans - they flow through the pipeline automatically
instrument_tracer:with_span(<<"process_order">>, fun() ->
    instrument_tracer:set_attributes(#{<<"order.id">> => <<"123">>}),
    do_work()
end).
```

## Environment Variables

Configure sampling and processing via environment variables:

### Sampler Configuration

| Variable | Description | Example Values |
|----------|-------------|----------------|
| `OTEL_TRACES_SAMPLER` | Sampler type | `always_on`, `always_off`, `traceidratio`, `parentbased_always_on`, `parentbased_always_off`, `parentbased_traceidratio` |
| `OTEL_TRACES_SAMPLER_ARG` | Sampler argument | `0.1` (for traceidratio) |

### Batch Processor Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `OTEL_BSP_SCHEDULE_DELAY` | Export interval in ms | `5000` |
| `OTEL_BSP_MAX_QUEUE_SIZE` | Max queue size | `2048` |
| `OTEL_BSP_MAX_EXPORT_BATCH_SIZE` | Max batch size | `512` |

### Using Environment Variables

```bash
# Sample 10% of traces with parent-based sampling
export OTEL_TRACES_SAMPLER=parentbased_traceidratio
export OTEL_TRACES_SAMPLER_ARG=0.1

# Configure batch processor
export OTEL_BSP_SCHEDULE_DELAY=2000
export OTEL_BSP_MAX_QUEUE_SIZE=4096
```

Then initialize configuration in your application:

```erlang
%% Read and apply environment variables
instrument_config:init().
```

## Examples

### Development Setup

Use simple processor with console exporter for immediate feedback:

```erlang
%% Sample everything
instrument_sampler:set_sampler(instrument_sampler_always_on).

%% Export immediately to console
instrument_span_processor:register(instrument_span_processor_simple, #{
    exporter => instrument_exporter_console,
    exporter_config => #{format => text}
}).
```

### Production Setup with 10% Sampling

```erlang
%% Parent-based 10% sampling
instrument_sampler:set_sampler(instrument_sampler_parent_based, #{
    root => instrument_sampler_probability,
    root_config => #{ratio => 0.1}
}).

%% Batch export to OTLP collector
instrument_span_processor:register(instrument_span_processor_batch, #{
    exporter => instrument_exporter_otlp,
    exporter_config => #{
        endpoint => "http://otel-collector:4318",
        compression => gzip
    }
}).
```

### High-Volume Setup

For high-throughput services, tune batch processor for efficiency:

```erlang
%% Low sampling rate
instrument_sampler:set_sampler(instrument_sampler_parent_based, #{
    root => instrument_sampler_probability,
    root_config => #{ratio => 0.01}  %% 1% sampling
}).

%% Optimized batch settings
instrument_span_processor:register(instrument_span_processor_batch, #{
    exporter => instrument_exporter_otlp,
    exporter_config => #{
        endpoint => "http://otel-collector:4318",
        compression => gzip,
        timeout => 10000
    },
    max_queue_size => 8192,
    max_export_batch_size => 1024,
    schedule_delay_millis => 1000  %% Export more frequently
}).
```

### Application Configuration

Configure via `sys.config`:

```erlang
[
  {instrument, [
    {sampler, {instrument_sampler_parent_based, #{
        root => instrument_sampler_probability,
        root_config => #{ratio => 0.1}
    }}},
    {span_processor, {instrument_span_processor_batch, #{
        max_queue_size => 4096,
        schedule_delay_millis => 2000,
        max_export_batch_size => 512
    }}},
    {span_exporter, {instrument_exporter_otlp, #{
        endpoint => <<"http://localhost:4318/v1/traces">>
    }}}
  ]}
].
```

### Graceful Shutdown

Ensure spans are exported before shutdown:

```erlang
stop(_State) ->
    %% Flush pending spans
    instrument_span_processor:force_flush(),
    %% Shutdown processors
    instrument_span_processor:shutdown(),
    ok.
```
