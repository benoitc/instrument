# Tracing Reference

Complete API reference for the distributed tracing system.

## Overview

The `instrument_tracer` module provides an OpenTelemetry-compatible tracing API with:

- Span creation and lifecycle management
- Attributes, events, and status
- Context propagation
- Multiple export options

## TracerProvider API

### `instrument_tracer:get_tracer/1`, `instrument_tracer:get_tracer/2`

Gets or creates a tracer.

```erlang
-spec get_tracer(Name) -> tracer() when
    Name :: binary() | atom().

-spec get_tracer(Name, Opts) -> tracer() when
    Name :: binary() | atom(),
    Opts :: #{
        version => binary(),
        schema_url => binary(),
        resource => map()
    }.
```

**Example:**

```erlang
Tracer = instrument_tracer:get_tracer(<<"my_service">>).
Tracer = instrument_tracer:get_tracer(my_service, #{version => <<"1.0.0">>}).
```

## Span Lifecycle

### `instrument_tracer:with_span/2`, `instrument_tracer:with_span/3`

Executes a function within a span. Recommended for most use cases.

```erlang
-spec with_span(Name, Fun) -> Result when
    Name :: binary() | atom(),
    Fun :: fun(() -> Result),
    Result :: term().

-spec with_span(Name, Opts, Fun) -> Result when
    Name :: binary() | atom(),
    Opts :: span_opts(),
    Fun :: fun(() -> Result),
    Result :: term().
```

**Span Options:**

```erlang
-type span_opts() :: #{
    kind => client | server | producer | consumer | internal,
    attributes => map(),
    links => [#span_link{}],
    start_time => integer(),
    parent => #span_ctx{} | undefined
}.
```

**Examples:**

```erlang
%% Basic span
Result = instrument_tracer:with_span(<<"operation">>, fun() ->
    do_work()
end).

%% Span with options
Result = instrument_tracer:with_span(<<"http_request">>, #{
    kind => server,
    attributes => #{<<"http.method">> => <<"GET">>}
}, fun() ->
    handle_request()
end).
```

**Behavior:**

- Automatically starts the span
- Captures exceptions and records them
- Sets error status on exceptions
- Re-raises exceptions after recording
- Ends the span in all cases (success, error, exception)

### `instrument_tracer:start_span/1`, `instrument_tracer:start_span/2`

Manually starts a span. Use when you need more control.

```erlang
-spec start_span(Name) -> span().
-spec start_span(Name, Opts) -> span().
```

**Example:**

```erlang
Span = instrument_tracer:start_span(<<"manual_operation">>),
try
    do_work()
after
    instrument_tracer:end_span(Span)
end.
```

### `instrument_tracer:end_span/0`, `instrument_tracer:end_span/1`

Ends a span.

```erlang
-spec end_span() -> ok.
-spec end_span(Span) -> ok when Span :: span().
```

### `instrument_tracer:current_span/0`

Returns the current span or `undefined`.

```erlang
-spec current_span() -> span() | undefined.
```

## Span Modification

### `instrument_tracer:set_attributes/1`

Sets multiple attributes on the current span.

```erlang
-spec set_attributes(Attrs) -> ok when
    Attrs :: map().
```

**Example:**

```erlang
instrument_tracer:set_attributes(#{
    <<"http.method">> => <<"GET">>,
    <<"http.url">> => <<"https://example.com/api">>,
    <<"http.status_code">> => 200
}).
```

### `instrument_tracer:set_attribute/2`

Sets a single attribute.

```erlang
-spec set_attribute(Key, Value) -> ok when
    Key :: term(),
    Value :: term().
```

### `instrument_tracer:add_event/1`, `instrument_tracer:add_event/2`

Adds a timestamped event to the span.

```erlang
-spec add_event(Name) -> ok when
    Name :: binary().

-spec add_event(Name, Attrs) -> ok when
    Name :: binary(),
    Attrs :: map().
```

**Example:**

```erlang
instrument_tracer:add_event(<<"cache_hit">>).
instrument_tracer:add_event(<<"query_executed">>, #{
    <<"db.rows_affected">> => 5
}).
```

### `instrument_tracer:set_status/1`, `instrument_tracer:set_status/2`

Sets the span status.

```erlang
-spec set_status(Status) -> ok when
    Status :: ok | error.

-spec set_status(error, Description) -> ok when
    Description :: binary().
```

**Example:**

```erlang
instrument_tracer:set_status(ok).
instrument_tracer:set_status(error, <<"Payment declined">>).
```

### `instrument_tracer:record_exception/1`, `instrument_tracer:record_exception/2`

Records an exception as a span event.

```erlang
-spec record_exception(Exception) -> ok when
    Exception :: term().

-spec record_exception(Exception, Opts) -> ok when
    Exception :: term(),
    Opts :: #{stacktrace => list()}.
```

**Example:**

```erlang
try
    risky_operation()
catch
    error:Reason:Stacktrace ->
        instrument_tracer:record_exception(Reason, #{
            stacktrace => Stacktrace
        }),
        handle_error(Reason)
end.
```

### `instrument_tracer:add_link/1`

Adds a link to another span.

```erlang
-spec add_link(SpanCtx | Opts) -> ok when
    SpanCtx :: #span_ctx{},
    Opts :: #{
        span_ctx := #span_ctx{},
        attributes => map()
    }.
```

### `instrument_tracer:update_name/1`

Updates the span name.

```erlang
-spec update_name(Name) -> ok when
    Name :: binary().
```

## SpanContext

### `instrument_tracer:span_ctx/0`, `instrument_tracer:span_ctx/1`

Gets the span context.

```erlang
-spec span_ctx() -> #span_ctx{} | undefined.
-spec span_ctx(Span) -> #span_ctx{}.
```

### `instrument_tracer:trace_id/0`, `instrument_tracer:trace_id/1`

Gets the trace ID as a hex string.

```erlang
-spec trace_id() -> binary() | undefined.
-spec trace_id(Span) -> binary().
```

### `instrument_tracer:span_id/0`, `instrument_tracer:span_id/1`

Gets the span ID as a hex string.

```erlang
-spec span_id() -> binary() | undefined.
-spec span_id(Span) -> binary().
```

### `instrument_tracer:is_recording/0`

Checks if the current span is recording.

```erlang
-spec is_recording() -> boolean().
```

### `instrument_tracer:is_sampled/0`

Checks if the current span is sampled.

```erlang
-spec is_sampled() -> boolean().
```

## Export

### `instrument_tracer:register_exporter/1`

Registers a span exporter function.

```erlang
-spec register_exporter(Exporter) -> ok when
    Exporter :: fun((span()) -> ok).
```

**Example:**

```erlang
%% Console exporter
instrument_tracer:register_exporter(
    fun(Span) -> instrument_exporter_console:export(Span) end
).

%% Custom exporter
instrument_tracer:register_exporter(fun(Span) ->
    io:format("Span: ~s (~.3f ms)~n", [
        Span#span.name,
        (Span#span.end_time - Span#span.start_time) / 1000000
    ])
end).
```

### `instrument_tracer:unregister_exporter/1`

Unregisters an exporter.

```erlang
-spec unregister_exporter(Exporter) -> ok.
```

## Context Module

The `instrument_context` module manages context propagation.

### `instrument_context:new/0`

Creates an empty context.

```erlang
-spec new() -> context().
```

### `instrument_context:current/0`

Returns the current context.

```erlang
-spec current() -> context().
```

### `instrument_context:attach/1`

Attaches a context, returning a token for detachment.

```erlang
-spec attach(Context) -> token().
```

### `instrument_context:detach/1`

Detaches and restores the previous context.

```erlang
-spec detach(Token) -> ok.
```

### `instrument_context:set_current/1`

Sets the current context without history (for spawned processes).

```erlang
-spec set_current(Context) -> ok.
```

### `instrument_context:with_context/2`

Executes a function with a context attached.

```erlang
-spec with_context(Context, Fun) -> Result.
```

### Context Values

```erlang
%% Get a value
Value = instrument_context:get_value(Ctx, Key).
Value = instrument_context:get_value(Ctx, Key, Default).

%% Set a value (returns new context)
NewCtx = instrument_context:set_value(Ctx, Key, Value).

%% Remove a value
NewCtx = instrument_context:remove_value(Ctx, Key).
```

### Process Spawning

```erlang
%% Spawn with context
Pid = instrument_context:spawn_with_context(Fun).
Pid = instrument_context:spawn_with_context(Module, Function).

%% Spawn linked with context
Pid = instrument_context:spawn_link_with_context(Fun).
Pid = instrument_context:spawn_link_with_context(Module, Function).
```

## Propagation Module

The `instrument_propagation` module handles cross-boundary propagation.

### Process Spawning

```erlang
Pid = instrument_propagation:spawn(Fun).
Pid = instrument_propagation:spawn(Fun, Args).
Pid = instrument_propagation:spawn_link(Fun).
Pid = instrument_propagation:spawn_link(Fun, Args).
{Pid, Ref} = instrument_propagation:spawn_monitor(Fun).
Pid = instrument_propagation:spawn_opt(Fun, Opts).
```

### Gen Server Integration

```erlang
%% Call with context
Result = instrument_propagation:call_with_context(Server, Request).
Result = instrument_propagation:call_with_context(Server, Request, Timeout).

%% Cast with context
ok = instrument_propagation:cast_with_context(Server, Msg).
```

### HTTP Headers

```erlang
%% Inject into headers
Headers = instrument_propagation:inject_headers(Context).
%% Returns: [{<<"traceparent">>, <<"00-...">>}, ...]

%% Extract from headers
Context = instrument_propagation:extract_headers(Headers).
```

### Generic Carrier

```erlang
%% Inject into map
Carrier = instrument_propagation:inject(#{}).
Carrier = instrument_propagation:inject(Context, #{}).

%% Extract from map
Context = instrument_propagation:extract(Carrier).
Context = instrument_propagation:extract(Carrier, BaseContext).
```

## Types

```erlang
-type tracer() :: #tracer{
    name :: binary(),
    version :: binary() | undefined,
    schema_url :: binary() | undefined,
    resource :: map() | undefined
}.

-type span() :: #span{
    name :: binary(),
    ctx :: #span_ctx{},
    parent_ctx :: #span_ctx{} | undefined,
    kind :: span_kind(),
    start_time :: integer(),
    end_time :: integer() | undefined,
    attributes :: map(),
    events :: [#span_event{}],
    links :: [#span_link{}],
    status :: ok | error | {error, binary()} | unset,
    is_recording :: boolean()
}.

-type span_ctx() :: #span_ctx{
    trace_id :: binary(),
    span_id :: binary(),
    trace_flags :: integer(),
    trace_state :: list(),
    is_remote :: boolean()
}.

-type span_kind() :: client | server | producer | consumer | internal.

-type context() :: #{term() => term()}.
-type token() :: reference().
```

## Span Kinds

| Kind | Description | Use Case |
|------|-------------|----------|
| `internal` | Default. Internal operation | Function calls, computations |
| `server` | Handles incoming request | HTTP server, gRPC server |
| `client` | Makes outgoing request | HTTP client, DB client |
| `producer` | Sends message | Queue producer, pub/sub |
| `consumer` | Receives message | Queue consumer, subscriber |

## Best Practices

### Span Naming

- Use descriptive, low-cardinality names
- Include operation type: `db_query`, `http_request`
- Avoid dynamic values in names (use attributes)

### Attributes

- Follow semantic conventions
- Include relevant context for debugging
- Avoid sensitive data

### Context Management

- Always detach attached contexts
- Use `with_span` when possible
- Propagate context across process boundaries

### Performance

- Don't create spans for trivial operations
- Check `is_recording()` before expensive attribute computation
- Use batch processor in production
