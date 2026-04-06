# Client Tracing Guide

Generic utilities for tracing client operations: databases, HTTP clients, message queues, RPC calls, and more.

## Overview

The `instrument_client` module provides reusable utilities for creating client-kind spans following OpenTelemetry semantic conventions. It works with any client operation type and automatically sets appropriate attributes based on the system type.

Key features:

- **Generic client spans** - Works for databases, HTTP, messaging, RPC
- **Text sanitization** - Remove sensitive data from queries and URLs
- **Trace context injection** - SQLCommenter-style trace propagation
- **Resource pool monitoring** - Track pool checkout/checkin
- **Attribute-based sampling** - Fine-grained sampling control

## Client Span Helpers

### Basic Usage

```erlang
%% Simple client span
instrument_client:with_client_span(postgresql, <<"SELECT">>, fun() ->
    epgsql:equery(Conn, SQL, Params)
end).

%% With options
instrument_client:with_client_span(postgresql, <<"SELECT">>, #{
    target => <<"users">>,
    statement => <<"SELECT * FROM users WHERE id = $1">>,
    sanitize => true,
    attributes => #{<<"db.name">> => <<"mydb">>}
}, fun() ->
    epgsql:equery(Conn, SQL, Params)
end).
```

### Manual Span Control

When you need more control over span lifecycle:

```erlang
Span = instrument_client:start_client_span(redis, <<"GET">>, #{
    target => <<"session:abc">>
}),
try
    Result = eredis:q(Conn, ["GET", "session:abc"]),
    instrument_tracer:set_status(ok),
    Result
catch
    _:Reason ->
        instrument_tracer:set_status(error, format_error(Reason)),
        erlang:raise(error, Reason, erlang:get_stacktrace())
after
    instrument_tracer:end_span(Span)
end.
```

### Span Naming

Span names follow semantic conventions: `system operation [target]`

```erlang
%% Without target: "postgresql SELECT"
instrument_client:client_span_name(postgresql, <<"SELECT">>).

%% With target: "postgresql SELECT users"
instrument_client:client_span_name(postgresql, <<"SELECT">>, #{target => <<"users">>}).
```

## Text Sanitization

Remove sensitive data from queries before including in spans.

### Basic Sanitization

```erlang
%% SQL: Replace string literals and numbers
instrument_client:sanitize_text(<<"SELECT * FROM users WHERE email = 'john@secret.com' AND id = 123">>).
%% => <<"SELECT * FROM users WHERE email = ? AND id = ?">>
```

### Custom Patterns

```erlang
%% URL path sanitization
instrument_client:sanitize_text(<<"/users/12345/orders">>, #{
    patterns => [<<"/\\d+">>],
    placeholder => <<"/:id">>
}).
%% => <<"/users/:id/orders">>

%% Preserve PostgreSQL placeholders
instrument_client:sanitize_text(
    <<"SELECT * FROM users WHERE id = $1 AND name = 'John'">>,
    #{preserve => [<<"\\$\\d+">>]}
).
%% => <<"SELECT * FROM users WHERE id = $1 AND name = ?">>
```

### Custom Placeholder

```erlang
instrument_client:sanitize_text(<<"WHERE x = 'secret'">>, #{
    placeholder => <<"<REDACTED>">>
}).
%% => <<"WHERE x = <REDACTED>">>
```

## Trace Context Propagation

Inject trace context into queries for database log correlation (SQLCommenter-style).

### SQL Comment Format

```erlang
instrument_tracer:with_span(<<"db_query">>, fun() ->
    SQL = <<"SELECT * FROM users">>,
    TracedSQL = instrument_client:inject_trace_comment(SQL),
    %% => <<"SELECT * FROM users /*traceparent='00-abc...-def...-01'*/">>
    epgsql:squery(Conn, TracedSQL)
end).
```

### URL Query Parameter Format

```erlang
URL = <<"/api/data">>,
TracedURL = instrument_client:inject_trace_comment(URL, #{format => url}).
%% => <<"/api/data?traceparent=00-abc...-def...-01">>
```

### Selective Injection

Only inject for verbose/debug mode:

```erlang
SQL = case instrument_config:is_verbose_tracing() of
    true -> instrument_client:inject_trace_comment(OriginalSQL);
    false -> OriginalSQL
end.
```

## Resource Pool Monitoring

Track connection pool checkout/checkin times separately from operation time.

### With Pool Span

```erlang
%% Wraps pool acquire/release around your operation
instrument_client:with_pool_span(<<"db_pool">>, postgresql, fun() ->
    Conn = poolboy:checkout(db_pool),
    try
        instrument_client:with_client_span(postgresql, <<"SELECT">>, #{
            target => <<"users">>
        }, fun() ->
            epgsql:equery(Conn, SQL, Params)
        end)
    after
        poolboy:checkin(db_pool, Conn)
    end
end).
```

### Manual Pool Spans

```erlang
%% Start acquisition span
AcquireSpan = instrument_client:pool_acquire_span(<<"db_pool">>, postgresql),
Conn = poolboy:checkout(db_pool),
instrument_tracer:end_span(AcquireSpan),

%% Use connection
Result = query(Conn, SQL),

%% Record release
poolboy:checkin(db_pool, Conn),
instrument_client:pool_release_span(<<"db_pool">>).
```

## Attribute Builders

### Build Attributes from Options

```erlang
Attrs = instrument_client:build_attributes(#{
    system => postgresql,
    operation => <<"SELECT">>,
    target => <<"users">>,
    statement => <<"SELECT * FROM users">>,
    sanitize => true,
    attributes => #{<<"db.name">> => <<"mydb">>}
}).
%% #{<<"db.system">> => <<"postgresql">>,
%%   <<"db.operation">> => <<"SELECT">>,
%%   <<"db.sql.table">> => <<"users">>,
%%   <<"db.statement">> => <<"SELECT * FROM users">>,
%%   <<"db.name">> => <<"mydb">>}
```

### Set Response Attributes

```erlang
instrument_client:with_client_span(postgresql, <<"SELECT">>, #{}, fun() ->
    case epgsql:equery(Conn, SQL, Params) of
        {ok, Cols, Rows} ->
            instrument_client:set_response_attributes(#{
                rows_returned => length(Rows)
            }),
            instrument_tracer:set_status(ok),
            {ok, Cols, Rows};
        {error, Reason} ->
            instrument_tracer:set_status(error, format_error(Reason)),
            {error, Reason}
    end
end).
```

## Attribute-Based Sampling

The `instrument_sampler_attribute` module provides fine-grained sampling control based on span attributes.

### Configuration

```erlang
instrument_sampler:set_sampler(instrument_sampler_attribute, #{
    default_ratio => 0.001,  %% 0.1% baseline
    attribute_rules => [
        %% Always sample errors
        {<<"error">>, true, 1.0},
        {<<"otel.status_code">>, <<"ERROR">>, 1.0},

        %% Lower rate for reads, higher for writes
        {<<"db.operation">>, <<"SELECT">>, 0.001},
        {<<"db.operation">>, <<"INSERT">>, 0.01},
        {<<"db.operation">>, <<"UPDATE">>, 0.01},
        {<<"db.operation">>, <<"DELETE">>, 0.05},

        %% Critical tables always sampled
        {<<"db.sql.table">>, <<"payments">>, 1.0},
        {<<"db.sql.table">>, <<"audit_log">>, 1.0}
    ]
}).
```

### Rule Matching

- Rules are evaluated in order
- First matching rule determines sampling rate
- If no rules match, `default_ratio` is used
- Same trace ID always produces same decision (deterministic)

### HTTP Example

```erlang
instrument_sampler:set_sampler(instrument_sampler_attribute, #{
    default_ratio => 0.1,
    attribute_rules => [
        {<<"http.method">>, <<"GET">>, 0.01},
        {<<"http.method">>, <<"POST">>, 0.1},
        {<<"http.status_code">>, 500, 1.0}  %% Always sample 500s
    ]
}).
```

### Messaging Example

```erlang
instrument_sampler:set_sampler(instrument_sampler_attribute, #{
    default_ratio => 0.05,
    attribute_rules => [
        {<<"messaging.destination">>, <<"critical-events">>, 1.0},
        {<<"messaging.operation">>, <<"process">>, 0.1}
    ]
}).
```

## Examples

### PostgreSQL with epgsql

```erlang
-module(myapp_db).
-export([query/3]).

query(Conn, SQL, Params) ->
    Op = detect_operation(SQL),
    Table = detect_table(SQL),

    instrument_client:with_client_span(postgresql, Op, #{
        target => Table,
        statement => SQL,
        sanitize => true,
        attributes => #{
            <<"db.name">> => <<"myapp">>,
            <<"db.user">> => <<"appuser">>
        }
    }, fun() ->
        %% Optional: inject trace context for DB log correlation
        TracedSQL = case instrument_config:is_verbose_tracing() of
            true -> instrument_client:inject_trace_comment(SQL);
            false -> SQL
        end,

        case epgsql:equery(Conn, TracedSQL, Params) of
            {ok, Cols, Rows} ->
                instrument_client:set_response_attributes(#{
                    rows_returned => length(Rows)
                }),
                instrument_tracer:set_status(ok),
                {ok, Cols, Rows};
            {error, Reason} ->
                instrument_tracer:set_status(error, format_error(Reason)),
                instrument_tracer:set_attribute(<<"db.error.code">>,
                    error_code(Reason)),
                {error, Reason}
        end
    end).

detect_operation(SQL) ->
    case SQL of
        <<"SELECT", _/binary>> -> <<"SELECT">>;
        <<"INSERT", _/binary>> -> <<"INSERT">>;
        <<"UPDATE", _/binary>> -> <<"UPDATE">>;
        <<"DELETE", _/binary>> -> <<"DELETE">>;
        _ -> <<"UNKNOWN">>
    end.

detect_table(SQL) ->
    %% Simple table detection - use a proper SQL parser for production
    case re:run(SQL, "(?:FROM|INTO|UPDATE)\\s+(\\w+)", [{capture, [1], binary}, caseless]) of
        {match, [Table]} -> Table;
        nomatch -> <<"unknown">>
    end.
```

### Redis with eredis

```erlang
-module(myapp_redis).
-export([cmd/2]).

cmd(Conn, Command) ->
    [Op | _] = Command,
    instrument_client:with_client_span(redis, Op, #{
        statement => iolist_to_binary(lists:join(<<" ">>, Command)),
        sanitize => true
    }, fun() ->
        case eredis:q(Conn, Command) of
            {ok, Result} ->
                instrument_tracer:set_status(ok),
                {ok, Result};
            {error, Reason} ->
                instrument_tracer:set_status(error, format_error(Reason)),
                {error, Reason}
        end
    end).
```

### Mnesia

```erlang
-module(myapp_mnesia).
-export([read/2, write/2]).

read(Tab, Key) ->
    instrument_client:with_client_span(mnesia, <<"read">>, #{
        target => atom_to_binary(Tab)
    }, fun() ->
        case mnesia:read(Tab, Key) of
            [] ->
                instrument_tracer:set_status(ok),
                [];
            Records ->
                instrument_client:set_response_attributes(#{
                    rows_returned => length(Records)
                }),
                instrument_tracer:set_status(ok),
                Records
        end
    end).

write(Tab, Record) ->
    instrument_client:with_client_span(mnesia, <<"write">>, #{
        target => atom_to_binary(Tab)
    }, fun() ->
        ok = mnesia:write(Tab, Record, write),
        instrument_tracer:set_status(ok),
        ok
    end).
```

### HTTP Client

```erlang
-module(myapp_http).
-export([request/3]).

request(Method, URL, Body) ->
    instrument_client:with_client_span(http, Method, #{
        target => extract_path(URL),
        attributes => #{
            <<"http.url">> => URL,
            <<"http.method">> => Method
        }
    }, fun() ->
        case hackney:request(Method, URL, [], Body, []) of
            {ok, StatusCode, _Headers, ClientRef} ->
                {ok, ResponseBody} = hackney:body(ClientRef),
                instrument_client:set_response_attributes(#{
                    status_code => StatusCode,
                    response_size => byte_size(ResponseBody)
                }),
                case StatusCode >= 400 of
                    true ->
                        instrument_tracer:set_status(error, <<"HTTP error">>);
                    false ->
                        instrument_tracer:set_status(ok)
                end,
                {ok, StatusCode, ResponseBody};
            {error, Reason} ->
                instrument_tracer:set_status(error, format_error(Reason)),
                {error, Reason}
        end
    end).
```

### Kafka Producer

```erlang
-module(myapp_kafka).
-export([publish/3]).

publish(Topic, Key, Value) ->
    instrument_client:with_client_span(kafka, <<"publish">>, #{
        target => Topic,
        attributes => #{
            <<"messaging.system">> => <<"kafka">>,
            <<"messaging.destination">> => Topic,
            <<"messaging.destination.kind">> => <<"topic">>
        }
    }, fun() ->
        case brod:produce_sync(client, Topic, Key, Value) of
            ok ->
                instrument_tracer:set_status(ok),
                ok;
            {error, Reason} ->
                instrument_tracer:set_status(error, format_error(Reason)),
                {error, Reason}
        end
    end).
```

## Runtime Controls

### Verbose Tracing

```erlang
%% WARNING: Only enable for debugging
instrument_config:set_verbose_tracing(true).
%% ... debug ...
instrument_config:set_verbose_tracing(false).
```

### Exporter Control

```erlang
%% Disable exporter during incident
instrument_config:disable_exporter(instrument_exporter_otlp).

%% Re-enable
instrument_config:enable_exporter(instrument_exporter_otlp).
```

## Production Recommendations

### Performance Overhead

| Operation | Overhead | Impact |
|-----------|----------|--------|
| Single client span | ~7 us | Negligible for most operations |
| Text sanitization | ~1-2 us | Scales with query length |
| Trace comment injection | ~0.5 us | Simple string concatenation |

For a 10ms database query, tracing adds approximately 0.07% overhead.

### Sampling Recommendations

| Throughput | Recommended Sampling |
|------------|---------------------|
| < 100 ops/sec | 100% (AlwaysOn) |
| 100 - 1K ops/sec | 10-50% |
| 1K - 10K ops/sec | 1-10% |
| 10K - 100K ops/sec | 0.1-1% |
| > 100K ops/sec | 0.01-0.1% + errors |

Always sample errors and slow operations regardless of rate.

### Production Configuration

```erlang
-module(myapp_tracing).
-export([configure/0]).

configure() ->
    instrument_sampler:set_sampler(instrument_sampler_attribute, #{
        default_ratio => 0.001,
        attribute_rules => [
            %% Always sample errors
            {<<"error">>, true, 1.0},
            {<<"otel.status_code">>, <<"ERROR">>, 1.0},

            %% Always sample slow operations
            {<<"slow_operation">>, true, 1.0},

            %% Higher rate for writes
            {<<"db.operation">>, <<"INSERT">>, 0.01},
            {<<"db.operation">>, <<"UPDATE">>, 0.01},
            {<<"db.operation">>, <<"DELETE">>, 0.05},

            %% DDL always sampled
            {<<"db.operation">>, <<"CREATE">>, 1.0},
            {<<"db.operation">>, <<"DROP">>, 1.0},
            {<<"db.operation">>, <<"ALTER">>, 1.0},

            %% Critical tables
            {<<"db.sql.table">>, <<"payments">>, 1.0}
        ]
    }),

    %% Ensure verbose tracing is OFF
    instrument_config:set_verbose_tracing(false),

    ok.
```

### Security Checklist

- [ ] Queries sanitized (no PII in spans)
- [ ] Verbose tracing disabled in production
- [ ] Error sampling at 100%
- [ ] Exporter timeouts configured
- [ ] Sensitive tables excluded or specially handled

### Marking Slow Operations

```erlang
{QueryTime, Result} = timer:tc(fun() -> do_query(Conn, SQL) end),
case QueryTime > 100000 of  %% > 100ms
    true ->
        instrument_tracer:set_attribute(<<"slow_operation">>, true);
    false ->
        ok
end.
```
