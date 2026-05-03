# Building Effective Spans

A span is more than a timer. A useful span also explains what was happening, which inputs mattered, and whether the operation succeeded.

## Span Attributes

Attributes are key-value pairs that describe the span. Backends index them, which makes traces searchable and useful for filtering.

### Setting Attributes

```erlang
instrument_tracer:with_span(<<"process_order">>, fun() ->
    %% Set multiple attributes at once
    instrument_tracer:set_attributes(#{
        <<"order.id">> => <<"ORD-12345">>,
        <<"customer.id">> => <<"CUST-789">>,
        <<"order.total">> => 149.99,
        <<"order.item_count">> => 5
    }),

    process(Order)
end).

%% Or set one at a time
instrument_tracer:set_attribute(<<"payment.method">>, <<"credit_card">>).
```

### Attribute Types

Attributes support these value types:

```erlang
%% Strings
instrument_tracer:set_attribute(<<"user.email">>, <<"alice@example.com">>).

%% Numbers
instrument_tracer:set_attribute(<<"http.status_code">>, 200).
instrument_tracer:set_attribute(<<"order.total">>, 49.99).

%% Booleans
instrument_tracer:set_attribute(<<"user.premium">>, true).
```

### Attribute Best Practices

**Useful attributes:**
- Request identifiers (order ID, transaction ID)
- User context (user ID, tenant ID, role)
- Request parameters (HTTP method, endpoint)
- Business data (order total, item count)
- Error details (error code, message)

**Attribute naming:**
- Use dot notation for namespacing: `http.method`, `db.operation`
- Use lowercase with underscores or dots
- Be consistent across your codebase

**Avoid:**
- Sensitive data (passwords, tokens, PII)
- High-cardinality values in excessive quantities
- Duplicate information already in the span name

## Span Events

Events mark points in time inside a span. They are useful for milestones: something happened, but it was not long enough or important enough to deserve its own child span.

### Adding Events

```erlang
instrument_tracer:with_span(<<"process_order">>, fun() ->
    instrument_tracer:add_event(<<"order_validated">>),

    Items = fetch_items(Order),
    instrument_tracer:add_event(<<"items_fetched">>, #{
        <<"count">> => length(Items)
    }),

    calculate_shipping(Items),
    instrument_tracer:add_event(<<"shipping_calculated">>),

    complete_order(Order)
end).
```

### Events vs Child Spans

Use events for:
- Quick checkpoints (validation passed, cache hit)
- Things that happen but don't have duration
- Debugging markers

Use child spans for:
- Operations with meaningful duration
- Operations you might want to optimize
- Work that might fail independently

```erlang
%% Event: quick check, no meaningful duration
instrument_tracer:add_event(<<"input_validated">>).

%% Span: database call with meaningful duration
instrument_tracer:with_span(<<"db_query">>, fun() ->
    run_query(SQL)
end).
```

## Recording Exceptions

The `with_span` function automatically records exceptions, but you can also record them manually:

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

Recorded exceptions appear as span events with:
- `exception.type`: The error type
- `exception.message`: Formatted error
- `exception.stacktrace`: Stack trace if provided

## Span Status

Set the span status to show whether the operation succeeded or failed:

```erlang
%% Successful operation
instrument_tracer:set_status(ok).

%% Failed operation
instrument_tracer:set_status(error).

%% Failed with description
instrument_tracer:set_status(error, <<"Payment declined">>).
```

Status values:
- `ok`: Operation completed successfully
- `error`: Operation failed
- `unset`: Default, no status set

### Status Best Practices

- Set `ok` for successful operations
- Set `error` for failures that need attention
- Include a description for errors
- Don't mark expected business outcomes as errors just because they are not successful paths

## Span Links

Links connect spans that are related but do not have a parent-child relationship:

```erlang
%% Link to a span from another trace
OtherSpanCtx = get_triggering_span_context(),
instrument_tracer:add_link(OtherSpanCtx).

%% Link with attributes
instrument_tracer:add_link(#{
    span_ctx => OtherSpanCtx,
    attributes => #{<<"link.reason">> => <<"retry">>}
}).
```

Use links for:
- Batch processing (link to all source items)
- Fan-out operations (link to triggering span)
- Retries (link to original attempt)

## Updating the Span Name

Sometimes you do not know the best span name until later:

```erlang
instrument_tracer:with_span(<<"http_request">>, fun() ->
    {Method, Path} = parse_request(Req),

    %% Update name with actual details
    instrument_tracer:update_name(<<Method/binary, " ", Path/binary>>),

    handle_request(Method, Path)
end).
```

## Span Options

Create spans with specific options:

```erlang
instrument_tracer:with_span(<<"operation">>, #{
    kind => server,
    attributes => #{<<"initial">> => <<"value">>},
    links => [OtherSpanCtx],
    start_time => erlang:system_time(nanosecond)
}, fun() ->
    do_work()
end).
```

Available options:
- `kind`: client, server, producer, consumer, internal
- `attributes`: Initial attributes map
- `links`: List of span contexts to link
- `start_time`: Override the start timestamp
- `parent`: Override the parent span context

## Complete Example: HTTP Handler

```erlang
-module(http_handler).
-export([handle/2]).

handle(Method, Path) ->
    instrument_tracer:with_span(<<"http_request">>, #{kind => server}, fun() ->
        %% Set HTTP attributes
        instrument_tracer:set_attributes(#{
            <<"http.method">> => Method,
            <<"http.target">> => Path,
            <<"http.scheme">> => <<"https">>
        }),

        %% Validate request
        case validate_request(Method, Path) of
            {error, Reason} ->
                instrument_tracer:set_status(error, Reason),
                {400, Reason};

            ok ->
                instrument_tracer:add_event(<<"request_validated">>),

                %% Process the request
                Result = instrument_tracer:with_span(<<"process_request">>, fun() ->
                    process(Method, Path)
                end),

                %% Set response attributes
                {Status, Body} = Result,
                instrument_tracer:set_attributes(#{
                    <<"http.status_code">> => Status
                }),

                case Status >= 400 of
                    true ->
                        instrument_tracer:set_status(error);
                    false ->
                        instrument_tracer:set_status(ok)
                end,

                Result
        end
    end).
```

## Exercise

Enhance the order processor from the previous chapter:

1. Add attributes for order ID, customer ID, and total
2. Add events for validation, payment processing, and completion
3. Record exceptions properly
4. Set appropriate status based on outcome

Then introduce a deliberate error and look at how it appears in the exported span.

## Next Steps

Your spans now carry useful context. Next, we will connect those spans across service and process boundaries.
