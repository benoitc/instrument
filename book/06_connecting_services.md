# Connecting Services

Modern systems span multiple services. This chapter covers how to maintain trace continuity across boundaries.

## The Challenge

When Service A calls Service B:

```
Service A                    Service B
┌─────────────┐             ┌─────────────┐
│ span A      │ ─── HTTP ─→ │ span B      │
└─────────────┘             └─────────────┘
```

Without propagation, span B starts a new trace. You lose the connection.

With propagation:

```
Trace: abc123
├── span A (Service A)
│   └── span B (Service B)
```

Both spans share the same trace ID.

## How Propagation Works

1. Service A injects trace context into the request
2. The context travels with the request (usually in headers)
3. Service B extracts the context
4. Service B creates a child span

## W3C TraceContext (Default)

The W3C TraceContext standard uses two headers:

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
tracestate: vendor1=value1,vendor2=value2
```

The `traceparent` header contains:
- Version (00)
- Trace ID (32 hex characters)
- Parent Span ID (16 hex characters)
- Trace flags (sampling decision)

## Injecting Context

Before making an outgoing request, inject the trace context:

```erlang
%% Create the outgoing span
instrument_tracer:with_span(<<"call_user_service">>, #{kind => client}, fun() ->
    %% Get current context
    Ctx = instrument_context:current(),

    %% Inject into headers
    Headers = instrument_propagation:inject_headers(Ctx),
    %% Headers: [{<<"traceparent">>, <<"00-abc...xyz-01">>}, ...]

    %% Make the HTTP request with these headers
    Response = httpc:request(get, {URL, Headers}, [], []),
    Response
end).
```

### Using with hackney

```erlang
call_service(URL, Body) ->
    instrument_tracer:with_span(<<"external_call">>, #{kind => client}, fun() ->
        instrument_tracer:set_attribute(<<"http.url">>, URL),

        %% Inject trace context into headers
        Headers = instrument_propagation:inject_headers(instrument_context:current()),

        %% Make request
        case hackney:request(post, URL, Headers, Body, []) of
            {ok, Status, _RespHeaders, ClientRef} ->
                {ok, RespBody} = hackney:body(ClientRef),
                instrument_tracer:set_attribute(<<"http.status_code">>, Status),
                {ok, Status, RespBody};
            {error, Reason} ->
                instrument_tracer:record_exception(Reason),
                instrument_tracer:set_status(error),
                {error, Reason}
        end
    end).
```

## Extracting Context

When receiving a request, extract the context before creating spans:

```erlang
handle_request(Req) ->
    %% Get headers from request
    Headers = get_headers(Req),

    %% Extract trace context
    Ctx = instrument_propagation:extract_headers(Headers),

    %% Attach context to this process
    Token = instrument_context:attach(Ctx),

    try
        %% Now spans will be children of the caller's span
        instrument_tracer:with_span(<<"handle_request">>, #{kind => server}, fun() ->
            process_request(Req)
        end)
    after
        instrument_context:detach(Token)
    end.
```

## B3 Propagation (Zipkin)

If you're integrating with Zipkin or systems using B3, configure B3 propagation:

```erlang
%% Via environment variable (before starting the app)
os:putenv("OTEL_PROPAGATORS", "b3"),
instrument_config:init().

%% Or programmatically
instrument_propagator:set_propagators([instrument_propagator_b3]).
```

B3 uses a single header:

```
b3: 80f198ee56343ba864fe8b2a57d3eff7-e457b5a2e4d86bd1-1-05e3ac9a4f6e3b90
```

For multi-header B3:

```erlang
os:putenv("OTEL_PROPAGATORS", "b3multi"),
instrument_config:init().
```

Multi-header B3 uses separate headers:

```
X-B3-TraceId: 80f198ee56343ba864fe8b2a57d3eff7
X-B3-SpanId: e457b5a2e4d86bd1
X-B3-Sampled: 1
X-B3-ParentSpanId: 05e3ac9a4f6e3b90
```

## Multiple Propagators

You can use multiple propagators simultaneously:

```erlang
os:putenv("OTEL_PROPAGATORS", "tracecontext,baggage,b3").
```

The library will inject all formats and extract from whichever is present.

## Propagation Within Erlang Processes

For communication between Erlang processes, use the propagation helpers:

### Spawning Processes

```erlang
%% Spawn with trace context
instrument_propagation:spawn(fun() ->
    instrument_tracer:with_span(<<"background_job">>, fun() ->
        do_work()
    end)
end).

%% Spawn linked with context
instrument_propagation:spawn_link(fun() ->
    process_async()
end).

%% Spawn with monitor
{Pid, Ref} = instrument_propagation:spawn_monitor(fun() ->
    do_monitored_work()
end).
```

### Gen Server Calls

For gen_server communication:

```erlang
%% Client side
Result = instrument_propagation:call_with_context(Server, {process, Data}).

%% Server side handle_call
handle_call({'$instrument_call', Ctx, {process, Data}}, From, State) ->
    Token = instrument_context:attach(Ctx),
    try
        Result = instrument_tracer:with_span(<<"process">>, fun() ->
            do_process(Data)
        end),
        {reply, Result, State}
    after
        instrument_context:detach(Token)
    end;
handle_call(Request, From, State) ->
    %% Handle non-instrumented calls normally
    {reply, ok, State}.
```

## Baggage

Baggage carries arbitrary key-value pairs across service boundaries:

```erlang
%% Set baggage
instrument_baggage:set(<<"user.id">>, <<"123">>),
instrument_baggage:set(<<"tenant">>, <<"acme">>).

%% Baggage is automatically propagated with trace context
Headers = instrument_propagation:inject_headers(instrument_context:current()).

%% On the receiving side, baggage is extracted automatically
Ctx = instrument_propagation:extract_headers(Headers),
instrument_context:attach(Ctx),

%% Read baggage
UserId = instrument_baggage:get(<<"user.id">>).
```

Use baggage for:
- User context needed across services
- Tenant identification
- Feature flags
- A/B test assignments

## Complete Example: Microservices

### Order Service

```erlang
-module(order_service).
-export([create_order/1]).

create_order(OrderData) ->
    instrument_tracer:with_span(<<"create_order">>, #{kind => server}, fun() ->
        instrument_tracer:set_attribute(<<"order.items">>, length(OrderData)),

        %% Validate with user service
        {ok, User} = call_user_service(OrderData),
        instrument_tracer:add_event(<<"user_validated">>),

        %% Check inventory
        {ok, Available} = call_inventory_service(OrderData),
        instrument_tracer:add_event(<<"inventory_checked">>),

        %% Process payment
        {ok, PaymentId} = call_payment_service(OrderData, User),
        instrument_tracer:set_attribute(<<"payment.id">>, PaymentId),

        instrument_tracer:set_status(ok),
        {ok, create_order_record(OrderData, PaymentId)}
    end).

call_user_service(OrderData) ->
    instrument_tracer:with_span(<<"call_user_service">>, #{kind => client}, fun() ->
        URL = "http://user-service/validate",
        Headers = instrument_propagation:inject_headers(instrument_context:current()),

        case hackney:request(post, URL, Headers, encode(OrderData), []) of
            {ok, 200, _, Ref} ->
                {ok, Body} = hackney:body(Ref),
                instrument_tracer:set_attribute(<<"http.status_code">>, 200),
                {ok, decode(Body)};
            {ok, Status, _, _} ->
                instrument_tracer:set_attribute(<<"http.status_code">>, Status),
                instrument_tracer:set_status(error),
                {error, Status}
        end
    end).
```

### User Service

```erlang
-module(user_service_handler).
-export([handle/1]).

handle(Req) ->
    Headers = cowboy_req:headers(Req),
    Ctx = instrument_propagation:extract_headers(maps:to_list(Headers)),
    Token = instrument_context:attach(Ctx),

    try
        instrument_tracer:with_span(<<"validate_user">>, #{kind => server}, fun() ->
            Body = cowboy_req:read_body(Req),
            UserId = extract_user_id(Body),

            instrument_tracer:set_attribute(<<"user.id">>, UserId),

            case validate_user(UserId) of
                {ok, User} ->
                    instrument_tracer:set_status(ok),
                    {200, #{}, encode(User)};
                {error, not_found} ->
                    instrument_tracer:set_status(error, <<"User not found">>),
                    {404, #{}, <<>>}
            end
        end)
    after
        instrument_context:detach(Token)
    end.
```

## Complete Example: Tracing Across Processes

Here is a runnable example showing trace context propagation across Erlang processes:

```erlang
-module(cross_process_trace).
-export([run/0]).

run() ->
    application:ensure_all_started(instrument),
    instrument_logger:install(),

    %% Register console exporter
    instrument_exporter:register(instrument_exporter_console:new()),

    %% Parent process creates a span
    instrument_tracer:with_span(<<"coordinator">>, #{kind => server}, fun() ->
        TraceId = instrument_tracer:trace_id(),
        logger:info("Coordinator started, trace_id=~s", [TraceId]),

        %% Spawn worker WITH context propagation
        WorkerPid = instrument_propagation:spawn(fun() ->
            %% This process inherits the trace context!
            instrument_tracer:with_span(<<"worker">>, fun() ->
                WorkerTraceId = instrument_tracer:trace_id(),
                logger:info("Worker running, trace_id=~s", [WorkerTraceId]),
                timer:sleep(50),
                instrument_tracer:set_status(ok)
            end)
        end),

        %% Wait for worker
        monitor(process, WorkerPid),
        receive {'DOWN', _, _, WorkerPid, _} -> ok end,

        instrument_tracer:set_status(ok)
    end).
```

Run it:

```
1> c(cross_process_trace).
2> cross_process_trace:run().
```

Expected output proving the same trace_id in both processes:

```
2024-01-15T10:30:00.123Z [INFO] [trace_id=a1b2c3d4... span_id=1111abcd...] Coordinator started, trace_id=a1b2c3d4...
2024-01-15T10:30:00.125Z [INFO] [trace_id=a1b2c3d4... span_id=2222efgh...] Worker running, trace_id=a1b2c3d4...

=== SPAN ===
Name:       worker
TraceId:    a1b2c3d4e5f67890a1b2c3d4e5f67890
SpanId:     2222efgh3333ijkl
ParentId:   1111abcd5555mnop      <-- Child of coordinator!
Kind:       internal
Duration:   50.12ms
Status:     OK
============

=== SPAN ===
Name:       coordinator
TraceId:    a1b2c3d4e5f67890a1b2c3d4e5f67890  <-- Same trace!
SpanId:     1111abcd5555mnop
ParentId:   none
Kind:       server
Duration:   52.34ms
Status:     OK
============
```

The key points:
- Both log lines show the **same trace_id**
- The worker span has the coordinator span as its parent
- This works because `instrument_propagation:spawn/1` copies the trace context

### Gen Server with Context Propagation

For gen_server processes, here is a complete example:

```erlang
-module(traced_worker).
-behaviour(gen_server).
-export([start_link/0, process/1]).
-export([init/1, handle_call/3, handle_cast/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

process(Data) ->
    %% Call with context propagation
    instrument_propagation:call_with_context(?MODULE, {process, Data}).

init([]) ->
    {ok, #{}}.

handle_call({'$instrument_call', Ctx, {process, Data}}, _From, State) ->
    Token = instrument_context:attach(Ctx),
    try
        Result = instrument_tracer:with_span(<<"worker_process">>, fun() ->
            logger:info("Processing: ~p", [Data]),
            timer:sleep(100),
            {ok, processed}
        end),
        {reply, Result, State}
    after
        instrument_context:detach(Token)
    end;
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.
```

Use it:

```erlang
test_gen_server() ->
    {ok, _} = traced_worker:start_link(),
    instrument_tracer:with_span(<<"main">>, fun() ->
        logger:info("Calling worker"),
        traced_worker:process(#{item => 123}),
        logger:info("Worker done")
    end).
```

## Exercise

Build a simple two-service system:

1. Service A: Accepts requests and calls Service B
2. Service B: Processes requests

Verify that:
- Spans from both services share the same trace ID
- The parent-child relationship is correct
- Attributes appear on both services' spans

## Next Steps

Your traces now flow across services. In the next chapter, you will learn how to correlate logs with traces.
