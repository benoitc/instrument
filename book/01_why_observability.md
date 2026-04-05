# Why Observability Matters

Before writing code, let's understand what observability means and when you need it.

## The Problem

Your Erlang application is running in production. Users report slow responses. Where do you look?

- Is the database slow?
- Is a specific endpoint causing issues?
- Are certain users affected more than others?
- Did the problem start after a recent deployment?

Without observability, you are flying blind.

## The Three Pillars

Observability rests on three types of telemetry:

### Metrics

Metrics are numeric measurements over time. They answer "how much" and "how many" questions:

- How many requests per second?
- What is the average response time?
- How many active connections?
- What percentage of requests fail?

Metrics are lightweight. You can collect thousands of metrics with minimal overhead.

### Traces

Traces follow a request through your system. They answer "what happened" questions:

- Which services did this request touch?
- Where did it spend the most time?
- What data did it process?
- Where did it fail?

Each trace contains spans representing units of work. Spans form a tree showing the request's path.

### Logs

Logs are timestamped records of events. They provide detailed context:

- What values did the function receive?
- What error message was returned?
- What decisions did the code make?

Logs become powerful when correlated with traces, letting you find the exact log lines for a problematic request.

## When to Use Each

**Use metrics when:**
- You need aggregated data (averages, percentiles, counts)
- You want to set up alerting thresholds
- You care about system-wide behavior
- You need low-overhead collection

**Use traces when:**
- You need to understand request flow
- You are debugging latency issues
- You have multiple services communicating
- You need to see the full picture of one request

**Use logs when:**
- You need detailed context about specific events
- You are debugging business logic
- You need human-readable records
- You want to capture unexpected conditions

## Why instrument?

The `instrument` library gives you all three pillars in one package:

```erlang
%% Metrics
Counter = instrument:new_counter(requests_total, <<"Total requests">>),
instrument:inc_counter(Counter).

%% Traces
instrument_tracer:with_span(<<"handle_request">>, fun() ->
    instrument_tracer:set_attribute(<<"user.id">>, UserId),
    process_request()
end).

%% Logs (with trace correlation)
instrument_logger:install(),
logger:info("Processing user ~s", [UserId]).  %% Includes trace_id
```

## The Cost of Not Observing

Without observability:

- Debugging takes hours instead of minutes
- You can't prove whether fixes work
- You react to problems instead of preventing them
- You can't understand your system's behavior

## What You Will Build

By the end of this book, you will have instrumented an Erlang application with:

- Request counters and latency histograms
- Distributed traces across services
- Correlated logs
- Export to Prometheus and Jaeger

Let's start by creating your first metrics.
