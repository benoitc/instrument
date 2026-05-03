# Why Observability Matters

Before writing code, it helps to be clear about the problem observability solves. The goal is not to collect data for its own sake. The goal is to answer production questions quickly and with evidence.

## The Problem

Your Erlang application is running in production. Users start reporting slow responses. Where do you look first?

- Is the database slow?
- Is a specific endpoint causing issues?
- Are certain users affected more than others?
- Did the problem start after a recent deployment?

Without observability, you mostly guess. You inspect logs, check dashboards, restart things, and hope the signal is somewhere nearby.

## The Three Pillars

Most observability systems work with three kinds of telemetry:

### Metrics

Metrics are numeric measurements over time. They answer "how much" and "how many" questions:

- How many requests per second?
- What is the average response time?
- How many active connections?
- What percentage of requests fail?

Metrics are compact and cheap to collect, which makes them a good fit for dashboards and alerts.

### Traces

Traces follow one request, job, or workflow through your system. They answer "what happened to this specific thing?" questions:

- Which services did this request touch?
- Where did it spend the most time?
- What data did it process?
- Where did it fail?

Each trace contains spans, and each span represents one unit of work. Together they form a tree that shows where the request went and where it spent time.

### Logs

Logs are timestamped records of events. They are where you keep detailed, human-readable context:

- What values did the function receive?
- What error message was returned?
- What decisions did the code make?

Logs are much easier to use when they are correlated with traces. Instead of searching around a timestamp, you can jump straight to the log lines for one failing request.

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

The `instrument` library gives you metrics, traces, and log correlation in one Erlang package:

```erlang
%% Metrics
Counter = instrument_metric:new_counter(requests_total, <<"Total requests">>),
instrument_metric:inc_counter(Counter).

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

When a system is not observable:

- Debugging takes hours instead of minutes
- You cannot prove whether a fix worked
- You react to problems after users notice them
- You build an inaccurate mental model of how the system behaves

## What You Will Build

By the end of this book, you will have instrumented an Erlang application with:

- Request counters and latency histograms
- Distributed traces across services
- Correlated logs
- Export to Prometheus and Jaeger

The first step is metrics, because they give you a fast, low-cost view of what the system is doing.
