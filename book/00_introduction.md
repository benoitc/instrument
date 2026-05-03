# Introduction

Welcome to the Erlang Observability Handbook. This book shows how to add useful observability to Erlang systems with the `instrument` library, without turning your application code into a pile of monitoring glue.

## What This Book Covers

You will learn how to:

- **Collect metrics**: Track counters, gauges, and histograms so you can see how the system behaves over time
- **Create traces**: Follow requests across processes and services with spans and context propagation
- **Correlate logs**: Connect ordinary Erlang logs to traces so debugging starts from the failing request, not from a timestamp guess
- **Export data**: Send telemetry to Prometheus, Jaeger, and OTLP-compatible backends

## Prerequisites

This book assumes you already have:

- Basic Erlang knowledge (modules, functions, processes)
- A working Erlang/OTP 25+ installation
- rebar3 for building projects

You do not need prior experience with observability tools. The early chapters explain the vocabulary before using it heavily.

## How to Read This Book

The chapters build on each other. If observability is new to you, start at the beginning and follow the examples in order. If you already know OpenTelemetry from another language, you can jump to the chapters that map directly to the Erlang parts you need.

**Part 1: Foundations**
- Chapter 1: Why Observability Matters
- Chapter 2: Your First Metrics
- Chapter 3: Adding Dimensions with Labels

**Part 2: Distributed Tracing**
- Chapter 4: Understanding Traces
- Chapter 5: Building Effective Spans
- Chapter 6: Connecting Services

**Part 3: Integration**
- Chapter 7: Logs That Tell the Story
- Chapter 8: Getting Data Out
- Chapter 9: Sampling for Scale

**Part 4: Putting It Together**
- Chapter 10: Complete Example

## Code Examples

The examples are meant to be copied into an Erlang shell or saved as small modules. Most examples focus on one idea at a time; the final chapter brings them together into a complete service.

```erlang
%% Start the instrument application
application:ensure_all_started(instrument).
```

## The instrument Library

`instrument` is a native Erlang observability library with OpenTelemetry compatibility. It provides:

- High-performance NIF-based metrics
- Distributed tracing with W3C TraceContext
- Multiple export formats (OTLP, Prometheus, Console)
- No external dependencies beyond hackney for HTTP

Install it in your `rebar.config`:

```erlang
{deps, [
    {instrument, "0.3.0"}
]}.
```

We will start with the practical question that motivates the rest of the book: when something is slow or broken in production, how do you find out what really happened?
