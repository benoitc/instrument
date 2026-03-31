# Context Propagation

This guide covers context propagation in depth, including manual context management without helpers.

## Table of Contents

1. [Understanding Context](#understanding-context)
2. [Context API](#context-api)
3. [Manual Context Management](#manual-context-management)
4. [Process Spawning](#process-spawning)
5. [Cross-Service Propagation](#cross-service-propagation)
6. [Baggage](#baggage)
7. [Advanced Patterns](#advanced-patterns)

## Understanding Context

Context is a mechanism for propagating request-scoped data across API boundaries and between processes. It carries:

- **Span Context**: Trace ID, span ID, and trace flags for distributed tracing
- **Baggage**: Key-value pairs that propagate across service boundaries
- **Custom Values**: Any application-specific data you want to propagate

Context is immutable. Every operation that modifies context returns a new context.

## Context API

### Creating and Manipulating Context

```erlang
%% Create a new empty context
Ctx = instrument_context:new().
%% Returns: #{}

%% Get the current context (from process dictionary)
Ctx = instrument_context:current().

%% Set a value in context (returns new context)
Ctx2 = instrument_context:set_value(Ctx, my_key, my_value).

%% Get a value from context
Value = instrument_context:get_value(Ctx2, my_key).
%% Returns: my_value

%% Get with default
Value = instrument_context:get_value(Ctx2, missing_key, default_value).
%% Returns: default_value

%% Remove a value (returns new context)
Ctx3 = instrument_context:remove_value(Ctx2, my_key).
```

### Attaching and Detaching Context

```erlang
%% Attach context to current process
%% Returns a token for proper restoration
Token = instrument_context:attach(Ctx).

%% ... do work with Ctx as the current context ...

%% Detach and restore previous context
ok = instrument_context:detach(Token).
```

**Important**: Always pair `attach` with `detach` to avoid context leaks. Use try/after for safety:

```erlang
safe_with_context(Ctx, Fun) ->
    Token = instrument_context:attach(Ctx),
    try
        Fun()
    after
        instrument_context:detach(Token)
    end.
```

### Scoped Context Execution

```erlang
%% Execute a function with a specific context
Result = instrument_context:with_context(Ctx, fun() ->
    %% Current context is Ctx here
    Current = instrument_context:current(),
    %% Current =:= Ctx
    do_work()
end).
%% Context is automatically restored after
```

## Manual Context Management

### Without Helpers: Basic Pattern

When you need full control over context propagation:

```erlang
%% Step 1: Capture current context
Ctx = instrument_context:current().

%% Step 2: Pass context explicitly or through message
spawn(fun() ->
    %% Step 3: Attach context in new process
    Token = instrument_context:attach(Ctx),
    try
        %% Step 4: Work is now in the same trace context
        do_work()
    after
        %% Step 5: Clean up
        instrument_context:detach(Token)
    end
end).
```

### Manual Span Propagation

```erlang
%% In the parent process
parent_process() ->
    %% Start a span
    _Span = instrument_tracer:start_span(<<"parent_operation">>),

    %% Get the full context (includes span_ctx)
    Ctx = instrument_context:current(),

    %% Spawn child and pass context
    Pid = spawn(fun() -> child_process(Ctx) end),

    %% Continue parent work...
    do_parent_work(),

    %% End parent span
    instrument_tracer:end_span().

%% In the child process
child_process(ParentCtx) ->
    %% Attach parent context
    Token = instrument_context:attach(ParentCtx),
    try
        %% Now we're in the same trace
        %% Start a child span (will be linked to parent)
        instrument_tracer:with_span(<<"child_operation">>, fun() ->
            do_child_work()
        end)
    after
        instrument_context:detach(Token)
    end.
```

### Extracting Span Context Directly

```erlang
%% Get just the span context record
SpanCtx = instrument_tracer:span_ctx().
%% Returns: #span_ctx{trace_id, span_id, trace_flags, trace_state, is_remote}

%% Or from a specific span
Span = instrument_tracer:start_span(<<"my_span">>),
SpanCtx = instrument_tracer:span_ctx(Span).

%% Access individual fields
TraceId = instrument_tracer:trace_id().       %% Hex string
SpanId = instrument_tracer:span_id().         %% Hex string
IsRecording = instrument_tracer:is_recording().
IsSampled = instrument_tracer:is_sampled().
```

### Building Context from Span Context

```erlang
%% If you have a span context from elsewhere
SpanCtx = #span_ctx{
    trace_id = TraceId,
    span_id = SpanId,
    trace_flags = 1,
    is_remote = true
}.

%% Build a context containing this span context
Ctx = instrument_context:new(),
Ctx2 = instrument_context:set_value(Ctx, span_ctx, SpanCtx).

%% Attach and create child spans
Token = instrument_context:attach(Ctx2),
try
    %% This span will be a child of SpanCtx
    instrument_tracer:with_span(<<"child">>, fun() ->
        do_work()
    end)
after
    instrument_context:detach(Token)
end.
```

## Process Spawning

### Manual Spawning (Without Helpers)

```erlang
%% Capture context before spawn
spawn_with_trace(Fun) ->
    Ctx = instrument_context:current(),
    spawn(fun() ->
        Token = instrument_context:attach(Ctx),
        try
            Fun()
        after
            instrument_context:detach(Token)
        end
    end).

%% With spawn_link
spawn_link_with_trace(Fun) ->
    Ctx = instrument_context:current(),
    spawn_link(fun() ->
        Token = instrument_context:attach(Ctx),
        try
            Fun()
        after
            instrument_context:detach(Token)
        end
    end).

%% With spawn_monitor
spawn_monitor_with_trace(Fun) ->
    Ctx = instrument_context:current(),
    spawn_monitor(fun() ->
        Token = instrument_context:attach(Ctx),
        try
            Fun()
        after
            instrument_context:detach(Token)
        end
    end).
```

### Using Helper Functions

The library provides helpers for common patterns:

```erlang
%% Simple spawn with context
Pid = instrument_propagation:spawn(fun() -> work() end).

%% Spawn link with context
Pid = instrument_propagation:spawn_link(fun() -> work() end).

%% Spawn monitor with context
{Pid, Ref} = instrument_propagation:spawn_monitor(fun() -> work() end).

%% Spawn with options
Pid = instrument_propagation:spawn_opt(fun() -> work() end, [link, {priority, high}]).
```

### gen_server Integration

```erlang
%% Without helpers: explicit context in messages
-module(my_server).
-behaviour(gen_server).

%% Client functions pass context
call_with_context(Pid, Request) ->
    Ctx = instrument_context:current(),
    gen_server:call(Pid, {with_ctx, Ctx, Request}).

cast_with_context(Pid, Msg) ->
    Ctx = instrument_context:current(),
    gen_server:cast(Pid, {with_ctx, Ctx, Msg}).

%% Server handles context
handle_call({with_ctx, Ctx, Request}, From, State) ->
    Token = instrument_context:attach(Ctx),
    try
        instrument_tracer:with_span(<<"handle_call">>, fun() ->
            do_handle_call(Request, From, State)
        end)
    after
        instrument_context:detach(Token)
    end;
handle_call(Request, From, State) ->
    %% No context - handle normally
    do_handle_call(Request, From, State).

handle_cast({with_ctx, Ctx, Msg}, State) ->
    Token = instrument_context:attach(Ctx),
    try
        instrument_tracer:with_span(<<"handle_cast">>, fun() ->
            do_handle_cast(Msg, State)
        end)
    after
        instrument_context:detach(Token)
    end.
```

Or use the provided helpers:

```erlang
%% Using helpers
Result = instrument_propagation:call_with_context(Pid, Request),
ok = instrument_propagation:cast_with_context(Pid, Msg).

%% Server side: check for wrapped messages
handle_call({'$instrument_call', Ctx, Request}, From, State) ->
    Token = instrument_context:attach(Ctx),
    try
        handle_call(Request, From, State)
    after
        instrument_context:detach(Token)
    end;
handle_call(Request, From, State) ->
    %% Normal handling
    ...
```

## Cross-Service Propagation

### Propagation Formats

The library supports multiple propagation formats:

#### W3C TraceContext (Default)

```
traceparent: 00-{trace_id}-{span_id}-{flags}
tracestate: vendor1=value1,vendor2=value2
baggage: key1=value1,key2=value2
```

#### B3 Single Header (Zipkin)

```
b3: {trace_id}-{span_id}-{sampling_state}-{parent_span_id}
```

Configure via environment or code:

```erlang
%% Environment variable
os:putenv("OTEL_PROPAGATORS", "b3"),
instrument_config:init().

%% Or programmatically
instrument_propagator:set_propagators([instrument_propagator_b3]).
```

#### B3 Multi Header (Zipkin)

```
X-B3-TraceId: {trace_id}
X-B3-SpanId: {span_id}
X-B3-ParentSpanId: {parent_span_id}
X-B3-Sampled: 0 or 1
X-B3-Flags: 1 (debug)
```

Configure:

```erlang
os:putenv("OTEL_PROPAGATORS", "b3multi"),
instrument_config:init().

%% Or programmatically
instrument_propagator:set_propagators([instrument_propagator_b3_multi]).
```

### Manual Header Injection

```erlang
%% Get current context
Ctx = instrument_context:current(),

%% Inject into a carrier map
Carrier = instrument_propagation:inject(Ctx, #{}),
%% Carrier now contains:
%% #{
%%   <<"traceparent">> => <<"00-abc123...-def456...-01">>,
%%   <<"tracestate">> => <<"...">>,
%%   <<"baggage">> => <<"key1=value1">>
%% }

%% Convert to HTTP headers format
Headers = maps:to_list(Carrier).
%% [{<<"traceparent">>, <<"...">>}, ...]
```

### Manual Header Extraction

```erlang
%% From HTTP headers (list of tuples)
Headers = [{<<"traceparent">>, <<"00-abc...-def...-01">>},
           {<<"baggage">>, <<"user_id=123">>}],

%% Extract into context
Ctx = instrument_propagation:extract_headers(Headers),

%% Attach and continue trace
Token = instrument_context:attach(Ctx),
try
    instrument_tracer:with_span(<<"handle_request">>, #{kind => server}, fun() ->
        %% This span continues the trace from the caller
        process_request()
    end)
after
    instrument_context:detach(Token)
end.
```

### Using inject/extract Directly

```erlang
%% Inject into any carrier map
Carrier = #{},
Carrier2 = instrument_propagation:inject(Ctx, Carrier).

%% Extract from any carrier map
Carrier = #{<<"traceparent">> => Value, ...},
Ctx = instrument_propagation:extract(Carrier).

%% Or extract into existing context
ExistingCtx = instrument_context:new(),
NewCtx = instrument_propagation:extract(Carrier, ExistingCtx).
```

### Raw Traceparent Parsing

For complete manual control:

```erlang
%% Parse traceparent header manually
Traceparent = <<"00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01">>,

%% Split into components
[Version, TraceIdHex, SpanIdHex, FlagsHex] = binary:split(Traceparent, <<"-">>, [global]),

%% Convert to binary
TraceId = instrument_id:hex_to_trace_id(TraceIdHex),
SpanId = instrument_id:hex_to_span_id(SpanIdHex),
Flags = binary_to_integer(FlagsHex, 16),

%% Build span context
SpanCtx = #span_ctx{
    trace_id = TraceId,
    span_id = SpanId,
    trace_flags = Flags,
    is_remote = true
},

%% Put into context
Ctx = instrument_context:set_value(instrument_context:new(), span_ctx, SpanCtx).
```

## Baggage

Baggage is key-value data that propagates across service boundaries.

### Setting and Getting Baggage

```erlang
%% Set baggage (updates current context)
ok = instrument_baggage:set(<<"user_id">>, <<"12345">>),
ok = instrument_baggage:set(<<"tenant">>, <<"acme">>),

%% Set with metadata
ok = instrument_baggage:set(<<"request_id">>, <<"req-abc">>, #{
    <<"propagation">> => <<"always">>
}),

%% Get baggage
UserId = instrument_baggage:get(<<"user_id">>),      %% <<"12345">>
Missing = instrument_baggage:get(<<"missing">>),     %% undefined
Default = instrument_baggage:get(<<"missing">>, <<"default">>),  %% <<"default">>

%% Get all baggage
All = instrument_baggage:get_all().
%% #{<<"user_id">> => <<"12345">>, <<"tenant">> => <<"acme">>}

%% Remove baggage
ok = instrument_baggage:remove(<<"user_id">>),

%% Clear all baggage
ok = instrument_baggage:clear().
```

### Manual Baggage with Context

```erlang
%% Get baggage from a context
Ctx = instrument_context:current(),
Baggage = instrument_baggage:from_context(Ctx).

%% Put baggage into a context
NewBaggage = #{<<"key">> => {<<"value">>, #{}}},
NewCtx = instrument_baggage:to_context(Ctx, NewBaggage).
```

### W3C Baggage Format

```erlang
%% Encode baggage to W3C format
Baggage = #{
    <<"user_id">> => {<<"123">>, #{}},
    <<"tenant">> => {<<"acme">>, #{}}
},
Encoded = instrument_baggage:encode(Baggage).
%% <<"user_id=123,tenant=acme">>

%% Decode from W3C format
Decoded = instrument_baggage:decode(<<"user_id=123,tenant=acme">>).
%% #{<<"user_id">> => {<<"123">>, #{}}, ...}
```

## Advanced Patterns

### Worker Pool with Trace Context

```erlang
-module(traced_pool).

%% Submit work with trace context
submit(Pool, Work) ->
    Ctx = instrument_context:current(),
    poolboy:transaction(Pool, fun(Worker) ->
        gen_server:call(Worker, {work, Ctx, Work})
    end).

%% Worker implementation
handle_call({work, Ctx, Work}, _From, State) ->
    Token = instrument_context:attach(Ctx),
    try
        Result = instrument_tracer:with_span(<<"pool_work">>, fun() ->
            execute_work(Work)
        end),
        {reply, Result, State}
    after
        instrument_context:detach(Token)
    end.
```

### Async Task with Context

```erlang
%% Start async task that preserves context
start_async_task(Task) ->
    Ctx = instrument_context:current(),
    Span = instrument_tracer:start_span(<<"async_task">>),
    SpanCtx = instrument_tracer:span_ctx(Span),

    Pid = spawn(fun() ->
        Token = instrument_context:attach(Ctx),
        try
            %% Restore span context for this task
            instrument_tracer:with_span(<<"async_work">>, #{
                parent => SpanCtx
            }, fun() ->
                execute_task(Task)
            end)
        after
            instrument_context:detach(Token),
            %% End the parent span when async work completes
            instrument_tracer:end_span(Span)
        end
    end),

    {ok, Pid}.
```

### Context in ETS/Persistent Storage

```erlang
%% Store context for later retrieval
store_context(Key) ->
    Ctx = instrument_context:current(),
    ets:insert(context_store, {Key, Ctx}).

%% Retrieve and use stored context
with_stored_context(Key, Fun) ->
    case ets:lookup(context_store, Key) of
        [{Key, Ctx}] ->
            Token = instrument_context:attach(Ctx),
            try
                Fun()
            after
                instrument_context:detach(Token)
            end;
        [] ->
            Fun()
    end.
```

### Timeout with Context Cleanup

```erlang
%% Execute with timeout, ensuring context cleanup
execute_with_timeout(Fun, Timeout) ->
    Parent = self(),
    Ctx = instrument_context:current(),

    {Pid, Ref} = spawn_monitor(fun() ->
        Token = instrument_context:attach(Ctx),
        try
            Result = Fun(),
            Parent ! {self(), {ok, Result}}
        catch
            Class:Reason:Stack ->
                Parent ! {self(), {error, Class, Reason, Stack}}
        after
            instrument_context:detach(Token)
        end
    end),

    receive
        {Pid, {ok, Result}} ->
            demonitor(Ref, [flush]),
            Result;
        {Pid, {error, Class, Reason, Stack}} ->
            demonitor(Ref, [flush]),
            erlang:raise(Class, Reason, Stack);
        {'DOWN', Ref, process, Pid, Reason} ->
            error({worker_died, Reason})
    after Timeout ->
        demonitor(Ref, [flush]),
        exit(Pid, kill),
        error(timeout)
    end.
```

---

## Summary

| Need | With Helpers | Without Helpers |
|------|--------------|-----------------|
| Get context | `instrument_context:current()` | Same |
| Set value | `instrument_context:set_value(Ctx, K, V)` | Same |
| Attach context | `instrument_context:attach(Ctx)` | Same |
| Spawn with context | `instrument_propagation:spawn(Fun)` | Capture + attach manually |
| HTTP inject | `instrument_propagation:inject_headers(Ctx)` | Build traceparent manually |
| HTTP extract | `instrument_propagation:extract_headers(Headers)` | Parse + build span_ctx |

Key principles:
1. Context is immutable - operations return new contexts
2. Always pair `attach` with `detach`
3. Use try/after for safe cleanup
4. Explicitly pass context across process boundaries
