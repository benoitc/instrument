# Semantic Conventions

Standard attribute names for consistent observability data.

## Overview

Semantic conventions define standard names for attributes, making telemetry data consistent and interoperable across services and tools.

Following these conventions ensures:

- Data is queryable in observability backends
- Dashboards and alerts work across services
- Teams use consistent terminology

## General Attributes

### Service

| Attribute | Type | Description |
|-----------|------|-------------|
| `service.name` | string | Logical name of the service |
| `service.version` | string | Version of the service |
| `service.namespace` | string | Namespace for multi-tenant services |
| `service.instance.id` | string | Unique instance identifier |

**Example:**

```erlang
instrument_tracer:set_attributes(#{
    <<"service.name">> => <<"order-service">>,
    <<"service.version">> => <<"1.2.3">>,
    <<"service.instance.id">> => node()
}).
```

### Deployment

| Attribute | Type | Description |
|-----------|------|-------------|
| `deployment.environment` | string | Environment name (production, staging) |

## HTTP Attributes

### Client and Server

| Attribute | Type | Description |
|-----------|------|-------------|
| `http.method` | string | HTTP method (GET, POST, etc.) |
| `http.url` | string | Full request URL |
| `http.target` | string | Request target (path + query) |
| `http.host` | string | Host header value |
| `http.scheme` | string | URL scheme (http, https) |
| `http.status_code` | int | HTTP response status code |
| `http.flavor` | string | HTTP version (1.1, 2.0) |
| `http.user_agent` | string | User-Agent header |
| `http.request_content_length` | int | Request body size in bytes |
| `http.response_content_length` | int | Response body size in bytes |

### Server-specific

| Attribute | Type | Description |
|-----------|------|-------------|
| `http.route` | string | Matched route pattern |
| `http.client_ip` | string | Client IP address |

**Example - HTTP Server:**

```erlang
instrument_tracer:with_span(<<"http_request">>, #{kind => server}, fun() ->
    instrument_tracer:set_attributes(#{
        <<"http.method">> => <<"POST">>,
        <<"http.target">> => <<"/api/orders">>,
        <<"http.route">> => <<"/api/orders">>,
        <<"http.scheme">> => <<"https">>,
        <<"http.host">> => <<"api.example.com">>,
        <<"http.status_code">> => 201,
        <<"http.client_ip">> => <<"192.168.1.100">>
    }),
    handle_request()
end).
```

**Example - HTTP Client:**

```erlang
instrument_tracer:with_span(<<"http_call">>, #{kind => client}, fun() ->
    instrument_tracer:set_attributes(#{
        <<"http.method">> => <<"GET">>,
        <<"http.url">> => <<"https://api.example.com/users/123">>,
        <<"http.status_code">> => 200
    }),
    make_request()
end).
```

## Database Attributes

| Attribute | Type | Description |
|-----------|------|-------------|
| `db.system` | string | Database type (postgresql, mysql, redis) |
| `db.connection_string` | string | Connection string (sanitized) |
| `db.user` | string | Database user |
| `db.name` | string | Database name |
| `db.statement` | string | SQL statement or command |
| `db.operation` | string | Operation type (SELECT, INSERT) |
| `db.sql.table` | string | Table being operated on |

**Example:**

```erlang
instrument_tracer:with_span(<<"db_query">>, #{kind => client}, fun() ->
    instrument_tracer:set_attributes(#{
        <<"db.system">> => <<"postgresql">>,
        <<"db.name">> => <<"orders">>,
        <<"db.user">> => <<"app_user">>,
        <<"db.operation">> => <<"SELECT">>,
        <<"db.sql.table">> => <<"orders">>,
        <<"db.statement">> => <<"SELECT * FROM orders WHERE id = $1">>
    }),
    execute_query()
end).
```

**Note:** Avoid including sensitive data in `db.statement`. Use parameterized queries.

## Messaging Attributes

| Attribute | Type | Description |
|-----------|------|-------------|
| `messaging.system` | string | Messaging system (rabbitmq, kafka) |
| `messaging.destination` | string | Queue/topic name |
| `messaging.destination_kind` | string | Kind (queue, topic) |
| `messaging.message_id` | string | Message identifier |
| `messaging.conversation_id` | string | Conversation/correlation ID |
| `messaging.message_payload_size_bytes` | int | Message size |
| `messaging.operation` | string | Operation (send, receive, process) |

**Example - Producer:**

```erlang
instrument_tracer:with_span(<<"send_message">>, #{kind => producer}, fun() ->
    instrument_tracer:set_attributes(#{
        <<"messaging.system">> => <<"rabbitmq">>,
        <<"messaging.destination">> => <<"orders.created">>,
        <<"messaging.destination_kind">> => <<"queue">>,
        <<"messaging.message_id">> => MessageId,
        <<"messaging.operation">> => <<"send">>
    }),
    publish_message()
end).
```

**Example - Consumer:**

```erlang
instrument_tracer:with_span(<<"process_message">>, #{kind => consumer}, fun() ->
    instrument_tracer:set_attributes(#{
        <<"messaging.system">> => <<"rabbitmq">>,
        <<"messaging.destination">> => <<"orders.created">>,
        <<"messaging.message_id">> => MessageId,
        <<"messaging.operation">> => <<"process">>
    }),
    handle_message()
end).
```

## RPC Attributes

| Attribute | Type | Description |
|-----------|------|-------------|
| `rpc.system` | string | RPC system (grpc, thrift) |
| `rpc.service` | string | Service name |
| `rpc.method` | string | Method name |
| `rpc.grpc.status_code` | int | gRPC status code |

**Example:**

```erlang
instrument_tracer:with_span(<<"grpc_call">>, #{kind => client}, fun() ->
    instrument_tracer:set_attributes(#{
        <<"rpc.system">> => <<"grpc">>,
        <<"rpc.service">> => <<"UserService">>,
        <<"rpc.method">> => <<"GetUser">>,
        <<"rpc.grpc.status_code">> => 0
    }),
    call_grpc()
end).
```

## Exception Attributes

| Attribute | Type | Description |
|-----------|------|-------------|
| `exception.type` | string | Exception class/type |
| `exception.message` | string | Exception message |
| `exception.stacktrace` | string | Stack trace as string |

These are set automatically by `record_exception/1,2`.

## Network Attributes

| Attribute | Type | Description |
|-----------|------|-------------|
| `net.transport` | string | Transport (ip_tcp, ip_udp) |
| `net.peer.ip` | string | Remote IP address |
| `net.peer.port` | int | Remote port |
| `net.peer.name` | string | Remote hostname |
| `net.host.ip` | string | Local IP address |
| `net.host.port` | int | Local port |
| `net.host.name` | string | Local hostname |

## Erlang-specific Attributes

While not part of the OTel specification, these are useful for Erlang applications:

| Attribute | Type | Description |
|-----------|------|-------------|
| `erlang.process.pid` | string | Process identifier |
| `erlang.process.name` | string | Registered process name |
| `erlang.node` | string | Node name |
| `erlang.application` | string | OTP application |
| `erlang.module` | string | Module name |
| `erlang.function` | string | Function name |

**Example:**

```erlang
instrument_tracer:set_attributes(#{
    <<"erlang.node">> => atom_to_binary(node()),
    <<"erlang.process.pid">> => list_to_binary(pid_to_list(self())),
    <<"erlang.module">> => <<"my_module">>,
    <<"erlang.function">> => <<"handle_call">>
}).
```

## Custom Attributes

For domain-specific data, use a namespace prefix:

```erlang
%% Order processing
instrument_tracer:set_attributes(#{
    <<"order.id">> => OrderId,
    <<"order.total">> => Total,
    <<"order.currency">> => <<"USD">>,
    <<"order.item_count">> => ItemCount,
    <<"order.customer_tier">> => <<"premium">>
}).

%% User context
instrument_tracer:set_attributes(#{
    <<"user.id">> => UserId,
    <<"user.email">> => Email,  %% Consider privacy implications
    <<"user.role">> => Role
}).

%% Feature flags
instrument_tracer:set_attributes(#{
    <<"feature.new_checkout">> => true,
    <<"feature.ab_test_variant">> => <<"B">>
}).
```

## Metric Naming Conventions

### Counter Names

- Use `_total` suffix
- Describe what is being counted
- Use lowercase with underscores

```erlang
http_requests_total
db_queries_total
messages_sent_total
errors_total
```

### Gauge Names

- Describe current state
- No special suffix needed

```erlang
http_active_connections
db_pool_size
queue_length
cache_size_bytes
```

### Histogram Names

- Include unit in name: `_seconds`, `_bytes`
- Describe what is measured

```erlang
http_request_duration_seconds
db_query_duration_seconds
response_size_bytes
message_size_bytes
```

### Label Names

- Use lowercase with underscores
- Keep names short but descriptive
- Be consistent across metrics

```erlang
method      %% HTTP method
status      %% Status code or status name
endpoint    %% API endpoint
operation   %% Database operation
pool        %% Connection pool name
```

## Best Practices

### Do

- Use standard attribute names when they exist
- Namespace custom attributes
- Include relevant context for debugging
- Be consistent across your codebase

### Don't

- Include sensitive data (passwords, tokens)
- Use high-cardinality attribute values excessively
- Duplicate information in span name and attributes
- Create new names when standards exist

### Attribute Value Guidelines

- **Strings**: Use lowercase, consistent formats
- **Numbers**: Use standard units (seconds, bytes)
- **Booleans**: Use for feature flags, binary states
- **Arrays**: Avoid unless necessary, impacts cardinality

### Privacy Considerations

Be careful with:

- User emails
- IP addresses
- Request bodies
- Authentication tokens
- Personal identifiers

Consider:

- Hashing sensitive values
- Using IDs instead of raw values
- Applying attribute filtering before export
