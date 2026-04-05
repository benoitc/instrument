# Introduction

Welcome to the Erlang Observability Handbook. This book will guide you through instrumenting your Erlang applications using the `instrument` library.

## What This Book Covers

You will learn how to:

- **Collect Metrics**: Track counters, gauges, and histograms to understand your system's behavior
- **Create Traces**: Follow requests across your distributed system with spans and context propagation
- **Correlate Logs**: Connect your existing logs to traces for debugging
- **Export Data**: Send telemetry to backends like Prometheus, Jaeger, and OTLP-compatible systems

## Prerequisites

This book assumes you have:

- Basic Erlang knowledge (modules, functions, processes)
- A working Erlang/OTP 25+ installation
- rebar3 for building projects

You do not need prior experience with observability tools.

## How to Read This Book

Each chapter builds on previous ones. Start from the beginning if you are new to observability. If you have experience with OpenTelemetry in other languages, you can skip to specific chapters.

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

All code examples are complete and runnable. You can type them into an Erlang shell or save them in modules.

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

Let's begin with understanding why observability matters for your systems.
