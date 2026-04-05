# Appendix A: Quick Reference

A cheat sheet for common operations.

## Metrics Quick Reference

### Counter

```erlang
%% Create
Counter = instrument:new_counter(requests_total, <<"Total requests">>).

%% Use
instrument:inc_counter(Counter).
instrument:inc_counter(Counter, 5).

%% Read
Value = instrument:get_counter(Counter).
```

### Gauge

```erlang
%% Create
Gauge = instrument:new_gauge(active_conns, <<"Active connections">>).

%% Use
instrument:set_gauge(Gauge, 100).
instrument:inc_gauge(Gauge).
instrument:dec_gauge(Gauge, 5).

%% Read
Value = instrument:get_gauge(Gauge).
```

### Histogram

```erlang
%% Create
Hist = instrument:new_histogram(duration_seconds, <<"Duration">>).
Hist = instrument:new_histogram(size_bytes, <<"Size">>, [100, 500, 1000]).

%% Use
instrument:observe_histogram(Hist, 0.125).

%% Read
#{count := C, sum := S, buckets := B} = instrument:get_histogram(Hist).
```

### Vector Metrics (Labeled)

```erlang
%% Create
instrument:new_counter_vec(http_requests, <<"Requests">>, [method, status]).
instrument:new_gauge_vec(pool_conns, <<"Pool">>, [pool, state]).
instrument:new_histogram_vec(query_time, <<"Query">>, [operation]).

%% Use
instrument:inc_counter_vec(http_requests, [<<"GET">>, <<"200">>]).
instrument:set_gauge_vec(pool_conns, [<<"default">>, <<"active">>], 10).
instrument:observe_histogram_vec(query_time, [<<"SELECT">>], 0.05).
```

## Tracing Quick Reference

### Basic Span

```erlang
instrument_tracer:with_span(<<"operation">>, fun() ->
    do_work()
end).
```

### Span with Options

```erlang
instrument_tracer:with_span(<<"operation">>, #{
    kind => server,          %% client | server | producer | consumer | internal
    attributes => #{<<"key">> => <<"value">>}
}, fun() ->
    do_work()
end).
```

### Span Attributes

```erlang
instrument_tracer:set_attribute(<<"key">>, <<"value">>).
instrument_tracer:set_attributes(#{
    <<"http.method">> => <<"GET">>,
    <<"http.status_code">> => 200
}).
```

### Span Events

```erlang
instrument_tracer:add_event(<<"event_name">>).
instrument_tracer:add_event(<<"event_name">>, #{<<"key">> => <<"value">>}).
```

### Span Status

```erlang
instrument_tracer:set_status(ok).
instrument_tracer:set_status(error).
instrument_tracer:set_status(error, <<"Error description">>).
```

### Exception Recording

```erlang
instrument_tracer:record_exception(Reason).
instrument_tracer:record_exception(Reason, #{stacktrace => Stacktrace}).
```

### Span Context

```erlang
TraceId = instrument_tracer:trace_id().   %% <<"abc123...">>
SpanId = instrument_tracer:span_id().      %% <<"def456...">>
IsRecording = instrument_tracer:is_recording().
IsSampled = instrument_tracer:is_sampled().
```

## Context Propagation

### HTTP Headers

```erlang
%% Inject (outgoing)
Headers = instrument_propagation:inject_headers(instrument_context:current()).

%% Extract (incoming)
Ctx = instrument_propagation:extract_headers(Headers),
Token = instrument_context:attach(Ctx),
%% ... do work ...
instrument_context:detach(Token).
```

### Process Spawning

```erlang
instrument_propagation:spawn(fun() -> work() end).
instrument_propagation:spawn_link(fun() -> work() end).
{Pid, Ref} = instrument_propagation:spawn_monitor(fun() -> work() end).
```

## Logging

```erlang
%% Install
instrument_logger:install().

%% Use (trace context added automatically)
logger:info("Message").
logger:error("Error: ~p", [Reason]).
```

## Export

### Prometheus

```erlang
Body = instrument_prometheus:format().
ContentType = instrument_prometheus:content_type().
```

### Console

```erlang
instrument_tracer:register_exporter(
    fun(Span) -> instrument_exporter_console:export(Span) end
).
```

### OTLP

```erlang
os:putenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318"),
instrument_config:init().
```

## Configuration

### Environment Variables

| Variable | Description |
|----------|-------------|
| `OTEL_SERVICE_NAME` | Service name |
| `OTEL_TRACES_SAMPLER` | Sampler type |
| `OTEL_TRACES_SAMPLER_ARG` | Sampler argument |
| `OTEL_PROPAGATORS` | Propagators (tracecontext, b3, baggage) |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | OTLP endpoint URL |

### Samplers

```erlang
os:putenv("OTEL_TRACES_SAMPLER", "always_on").
os:putenv("OTEL_TRACES_SAMPLER", "always_off").
os:putenv("OTEL_TRACES_SAMPLER", "traceidratio").
os:putenv("OTEL_TRACES_SAMPLER", "parentbased_traceidratio").
os:putenv("OTEL_TRACES_SAMPLER_ARG", "0.1").  %% 10%
```

## Decision Trees

### Which Metric Type?

```
Does the value only increase?
├── Yes → Counter
└── No
    Does it represent a distribution?
    ├── Yes → Histogram
    └── No → Gauge
```

### Should I Create a Span?

```
Is this an entry point (HTTP request, message)?
├── Yes → Create server/consumer span
└── No
    Is this an outgoing call (HTTP, DB)?
    ├── Yes → Create client/producer span
    └── No
        Is this significant internal work?
        ├── Yes → Create internal span
        └── No → Don't create a span
```

### Should I Use Labels?

```
Do I need to filter/group this metric?
├── No → Simple metric
└── Yes
    Is the cardinality bounded (<100 values)?
    ├── Yes → Use labels
    └── No
        Can I bucket/categorize values?
        ├── Yes → Use categorized labels
        └── No → Use span attributes instead
```

## Common Patterns

### HTTP Handler

```erlang
handle(Req) ->
    Ctx = instrument_propagation:extract_headers(Headers),
    Token = instrument_context:attach(Ctx),
    try
        instrument_tracer:with_span(<<"http_request">>, #{kind => server}, fun() ->
            instrument_tracer:set_attributes(#{
                <<"http.method">> => Method,
                <<"http.target">> => Path
            }),
            Result = process(Req),
            instrument_tracer:set_attribute(<<"http.status_code">>, Status),
            Result
        end)
    after
        instrument_context:detach(Token)
    end.
```

### Database Call

```erlang
query(SQL, Params) ->
    instrument_tracer:with_span(<<"db_query">>, #{kind => client}, fun() ->
        instrument_tracer:set_attributes(#{
            <<"db.system">> => <<"postgresql">>,
            <<"db.operation">> => <<"SELECT">>,
            <<"db.statement">> => SQL
        }),
        execute(SQL, Params)
    end).
```

### External Service Call

```erlang
call_service(URL, Body) ->
    instrument_tracer:with_span(<<"external_call">>, #{kind => client}, fun() ->
        Headers = instrument_propagation:inject_headers(instrument_context:current()),
        Result = http_request(URL, Headers, Body),
        Result
    end).
```
