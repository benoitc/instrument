# Exporters Guide

This guide covers exporting telemetry data (spans, metrics, logs) to various backends.

## Table of Contents

1. [Overview](#overview)
2. [Span Exporters](#span-exporters)
   - [Console Exporter](#console-exporter)
   - [OTLP Exporter](#otlp-exporter)
3. [Metrics Exporters](#metrics-exporters)
   - [Metrics Console Exporter](#metrics-console-exporter)
   - [Metrics OTLP Exporter](#metrics-otlp-exporter)
4. [Log Exporters](#log-exporters)
   - [Log Console Exporter](#log-console-exporter)
   - [Log File Exporter](#log-file-exporter)
   - [Log OTLP Exporter](#log-otlp-exporter)
5. [Custom Exporters](#custom-exporters)
6. [Batch Processing](#batch-processing)
7. [Configuration](#configuration)
8. [Sending to External Collectors](#sending-to-external-collectors)
   - [OpenTelemetry Collector](#opentelemetry-collector)
   - [Jaeger](#jaeger)
   - [Grafana Tempo](#grafana-tempo)
   - [Cloud Backends](#cloud-backends)

## Overview

The instrument library provides export systems for spans (traces), metrics, and logs. All systems support batch export and multiple simultaneous backends.

- **Span exporters** handle trace data via `instrument_exporter`
- **Metrics exporters** handle metric data via `instrument_metrics_exporter`
- **Log exporters** handle log data via `instrument_log_exporter`

All exporter systems start automatically with the application.

### Quick Start

```erlang
%% Register span exporters
instrument_exporter:register(instrument_exporter_console:new()),
instrument_exporter:register(instrument_exporter_otlp:new(#{
    endpoint => "http://localhost:4318"
})),

%% Register metrics exporters
instrument_metrics_exporter:register(instrument_metrics_exporter_console:new()),
instrument_metrics_exporter:register(instrument_metrics_exporter_otlp:new(#{
    endpoint => "http://localhost:4318"
})),

%% Register log exporters
instrument_log_exporter:register(instrument_log_exporter_console:new()),
instrument_log_exporter:register(instrument_log_exporter_otlp:new(#{
    endpoint => "http://localhost:4318"
})),
%% Enable log export via logger
instrument_logger:install(#{exporter => true}),

%% Spans are exported when they end
instrument_tracer:with_span(<<"my_operation">>, fun() ->
    do_work()
end).

%% Metrics are collected and exported periodically (default: 60s)
instrument_metric:inc_counter(my_counter).

%% Logs are exported when using logger
logger:info("This will be exported with trace context").
```

## Span Exporters

### Console Exporter

The console exporter prints spans to stdout or a file. Useful for debugging and development.

### Basic Usage

```erlang
%% Default: text format to stdout
instrument_exporter:register(instrument_exporter_console:new()).
```

### Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `format` | `text \| json` | `text` | Output format |
| `output` | `standard_io \| standard_error \| {file, Path}` | `standard_io` | Output destination |

### Text Format

```erlang
instrument_exporter:register(instrument_exporter_console:new(#{
    format => text
})).
```

Output example:

```
=== SPAN ===
Name:       process_order
TraceId:    abc123def456...
SpanId:     789xyz...
ParentId:   none
Kind:       server
Duration:   125.34ms
Status:     OK
Attributes:
  order.id: <<"12345">>
  customer.id: <<"67890">>
Events:
  @2024-01-15T10:30:45.123456Z: order_validated
  @2024-01-15T10:30:45.234567Z: payment_processed
============
```

### JSON Format

```erlang
instrument_exporter:register(instrument_exporter_console:new(#{
    format => json
})).
```

Output example (one line per span):

```json
{"name":"process_order","traceId":"abc123...","spanId":"789xyz...","kind":"server","status":{"code":"OK"},...}
```

### Writing to File

```erlang
instrument_exporter:register(instrument_exporter_console:new(#{
    format => json,
    output => {file, "/var/log/traces.jsonl"}
})).
```

### OTLP Exporter

The OTLP exporter sends spans to an OpenTelemetry Collector or compatible backend using OTLP/HTTP with JSON encoding.

### Basic Usage

```erlang
%% Export to local collector
instrument_exporter:register(instrument_exporter_otlp:new(#{
    endpoint => "http://localhost:4318"
})).
```

### Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `endpoint` | `string \| binary` | required | Base URL of OTLP receiver |
| `headers` | `map` | `#{}` | Additional HTTP headers |
| `compression` | `none \| gzip` | `none` | Request compression |
| `timeout` | `integer` | `10000` | Request timeout in ms |
| `traces_path` | `binary` | `<<"/v1/traces">>` | API path |

### With Authentication

```erlang
instrument_exporter:register(instrument_exporter_otlp:new(#{
    endpoint => "https://otel.example.com:4318",
    headers => #{
        <<"Authorization">> => <<"Bearer your-api-key">>,
        <<"X-Custom-Header">> => <<"value">>
    }
})).
```

### With Compression

```erlang
instrument_exporter:register(instrument_exporter_otlp:new(#{
    endpoint => "http://localhost:4318",
    compression => gzip
})).
```

### Configuring Service Name

Set the service name via application environment:

```erlang
%% In sys.config
{instrument, [
    {service_name, <<"my-service">>}
]}
```

Or at runtime:

```erlang
application:set_env(instrument, service_name, <<"my-service">>).
```

## Metrics Exporters

The metrics exporter system collects and exports metrics periodically (default: 60 seconds). Metrics are collected from the instrument registry and sent to all registered exporters.

### Metrics Console Exporter

The console exporter prints metrics to stdout for debugging.

#### Basic Usage

```erlang
%% Default: text format to stdout
instrument_metrics_exporter:register(instrument_metrics_exporter_console:new()).
```

#### Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `format` | `text \| json` | `text` | Output format |
| `output` | `standard_io \| standard_error \| {file, Path}` | `standard_io` | Output destination |

#### Text Format

```erlang
instrument_metrics_exporter:register(instrument_metrics_exporter_console:new(#{
    format => text
})).
```

Output example:

```
# HTTP request counter
[2026-03-31T12:00:00.000000Z] http_requests_total{method="GET",status="200"} 1234
[2026-03-31T12:00:00.000000Z] active_connections{} 42
```

#### JSON Format

```erlang
instrument_metrics_exporter:register(instrument_metrics_exporter_console:new(#{
    format => json
})).
```

Output example (one line per metric):

```json
{"name":"http_requests_total","type":"counter","dataPoints":[{"attributes":{},"value":1234,"timeUnixNano":1711879200000000000}]}
```

### Metrics OTLP Exporter

The OTLP metrics exporter sends metrics to an OpenTelemetry Collector using OTLP/HTTP with JSON encoding.

#### Basic Usage

```erlang
instrument_metrics_exporter:register(instrument_metrics_exporter_otlp:new(#{
    endpoint => "http://localhost:4318"
})).
```

#### Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `endpoint` | `string \| binary` | required | Base URL of OTLP receiver |
| `headers` | `map` | `#{}` | Additional HTTP headers |
| `compression` | `none \| gzip` | `none` | Request compression |
| `timeout` | `integer` | `10000` | Request timeout in ms |
| `metrics_path` | `binary` | `<<"/v1/metrics">>` | API path |

#### With Authentication

```erlang
instrument_metrics_exporter:register(instrument_metrics_exporter_otlp:new(#{
    endpoint => "https://otel.example.com:4318",
    headers => #{
        <<"Authorization">> => <<"Bearer your-api-key">>
    }
})).
```

#### With Compression

```erlang
instrument_metrics_exporter:register(instrument_metrics_exporter_otlp:new(#{
    endpoint => "http://localhost:4318",
    compression => gzip
})).
```

### Metrics Export Configuration

Configure the export interval via application environment:

```erlang
%% In sys.config
{instrument, [
    {metrics_export_interval, 30000}  %% 30 seconds
]}
```

Or at runtime:

```erlang
application:set_env(instrument, metrics_export_interval, 30000).
```

### Manual Metrics Flush

Force immediate export of metrics:

```erlang
ok = instrument_metrics_exporter:flush().
```

## Log Exporters

The log exporter system integrates with Erlang's logger to export log records to various backends. Log records include trace context when available, enabling correlation between logs and traces.

### Log Console Exporter

The console log exporter prints log records to stdout or stderr. Useful for debugging and development.

#### Basic Usage

```erlang
%% Register console exporter for logs
instrument_log_exporter:register(instrument_log_exporter_console:new()),

%% Enable exporter mode in logger
instrument_logger:install(#{exporter => true}).
```

#### Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `format` | `text \| json` | `text` | Output format |
| `output` | `standard_io \| standard_error` | `standard_io` | Output destination |

#### Text Format

```erlang
instrument_log_exporter:register(instrument_log_exporter_console:new(#{
    format => text
})).
```

Output example:

```
[2026-03-31T12:00:00.000000Z] INFO [trace_id=abc123... span_id=def456...] User logged in {"user":"john"}
```

#### JSON Format

```erlang
instrument_log_exporter:register(instrument_log_exporter_console:new(#{
    format => json
})).
```

Output example (OTLP-compatible, one line per log):

```json
{"timeUnixNano":"...","severityText":"INFO","body":{"stringValue":"User logged in"},"traceId":"...","spanId":"..."}
```

### Log File Exporter

The file log exporter writes log records to a file with optional rotation support.

#### Basic Usage

```erlang
instrument_log_exporter:register(instrument_log_exporter_file:new(#{
    path => "/var/log/app.log"
})).
```

#### Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `path` | `string \| binary` | required | Log file path |
| `format` | `text \| json` | `text` | Output format |
| `max_size` | `integer` | `10485760` | Max file size in bytes (10MB), 0 = unlimited |
| `max_files` | `integer` | `5` | Number of rotated files to keep |
| `compress` | `boolean` | `false` | Compress rotated files with gzip |

#### With Rotation

```erlang
instrument_log_exporter:register(instrument_log_exporter_file:new(#{
    path => "/var/log/app.log",
    format => json,
    max_size => 52428800,   %% 50MB
    max_files => 10,
    compress => true
})).
```

File rotation behavior:
- When `max_size` is reached: `app.log` -> `app.log.1` -> `app.log.2` -> ...
- If `compress=true`: rotated files become `app.log.1.gz`, `app.log.2.gz`, etc.
- Oldest files beyond `max_files` are deleted

### Log OTLP Exporter

The OTLP log exporter sends log records to an OpenTelemetry Collector using OTLP/HTTP with JSON encoding.

#### Basic Usage

```erlang
instrument_log_exporter:register(instrument_log_exporter_otlp:new(#{
    endpoint => "http://localhost:4318"
})).
```

#### Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `endpoint` | `string \| binary` | required | Base URL of OTLP receiver |
| `headers` | `map` | `#{}` | Additional HTTP headers |
| `compression` | `none \| gzip` | `none` | Request compression |
| `timeout` | `integer` | `10000` | Request timeout in ms |
| `logs_path` | `binary` | `<<"/v1/logs">>` | API path |

#### With Authentication

```erlang
instrument_log_exporter:register(instrument_log_exporter_otlp:new(#{
    endpoint => "https://otel.example.com:4318",
    headers => #{
        <<"Authorization">> => <<"Bearer your-api-key">>
    },
    compression => gzip
})).
```

### Logger Integration

To enable log export, install the logger integration with exporter mode:

```erlang
%% Register exporters first
instrument_log_exporter:register(instrument_log_exporter_console:new()),

%% Enable exporter mode (logs go to registered exporters)
instrument_logger:install(#{exporter => true}).

%% Now logs are automatically exported
logger:info("This message will be exported"),
logger:error("This error will be exported with trace context").
```

Within a span, logs automatically include trace context:

```erlang
instrument_tracer:with_span(<<"process_order">>, fun() ->
    logger:info("Processing order"),  %% Includes trace_id and span_id
    do_work()
end).
```

### Manual Log Flush

Force immediate export of pending logs:

```erlang
ok = instrument_log_exporter:flush().
```

## Custom Exporters

You can create custom exporters by implementing the exporter behaviour.

### Behaviour Callbacks

```erlang
-module(my_exporter).

%% Required callbacks
-export([init/1, export/2, shutdown/1, force_flush/1]).

%% Initialize the exporter
%% Config is the map passed during registration
-spec init(Config :: map()) -> {ok, State} | {error, Reason}.
init(Config) ->
    %% Setup your exporter
    {ok, #state{...}}.

%% Export a batch of spans
%% Called periodically or when batch is full
-spec export(Spans :: [#span{}], State) -> {ok, NewState} | {error, Reason, NewState}.
export(Spans, State) ->
    %% Send spans to your backend
    lists:foreach(fun(Span) ->
        send_to_backend(Span, State)
    end, Spans),
    {ok, State}.

%% Shutdown the exporter
%% Called when unregistered or application stops
-spec shutdown(State) -> ok.
shutdown(State) ->
    %% Cleanup resources
    ok.

%% Force flush pending data
%% Called on explicit flush
-spec force_flush(State) -> {ok, NewState}.
force_flush(State) ->
    {ok, State}.
```

## Batch Processing

The exporter manager batches spans for efficient export.

### Batch Configuration

Default settings:
- **Batch size**: 512 spans
- **Batch timeout**: 5000ms (5 seconds)

Spans are exported when either threshold is reached.

### Manual Flush

Force immediate export of pending spans:

```erlang
%% Flush all pending spans
ok = instrument_exporter:flush().
```

### Shutdown

Gracefully shutdown all exporters (flushes pending spans first):

```erlang
ok = instrument_exporter:shutdown().
```

## Configuration

### Multiple Exporters

You can register multiple exporters simultaneously:

```erlang
%% Console for debugging
instrument_exporter:register(instrument_exporter_console:new(#{
    format => text
})),

%% OTLP for collector
instrument_exporter:register(instrument_exporter_otlp:new(#{
    endpoint => "http://localhost:4318"
})),

%% Custom exporter for specific needs
instrument_exporter:register(my_custom_exporter:new(#{...})).
```

### Listing Exporters

```erlang
%% Get list of registered exporter modules
Exporters = instrument_exporter:list().
%% [instrument_exporter_console, instrument_exporter_otlp, ...]
```

### Unregistering Exporters

```erlang
%% Unregister a specific exporter
ok = instrument_exporter:unregister(instrument_exporter_console).
```

## Production Recommendations

1. **Use OTLP exporter** for production with a collector (Jaeger, Zipkin, etc.)

2. **Enable compression** for high-volume scenarios:
   ```erlang
   instrument_exporter_otlp:new(#{
       endpoint => "...",
       compression => gzip
   })
   ```

3. **Set appropriate timeouts** based on your network:
   ```erlang
   instrument_exporter_otlp:new(#{
       endpoint => "...",
       timeout => 30000  %% 30 seconds for slow networks
   })
   ```

4. **Use console exporter only for debugging** - it's not designed for production load

5. **Flush before shutdown** in your application stop:
   ```erlang
   stop(_State) ->
       instrument_exporter:flush(),
       ok.
   ```

## Sending to External Collectors

The OTLP exporter can send telemetry to any OTLP-compatible backend. Here are common configurations.

### OpenTelemetry Collector

The OpenTelemetry Collector is a vendor-agnostic proxy that receives, processes, and exports telemetry data.

**Docker Setup:**

```bash
# Run the collector
docker run -p 4317:4317 -p 4318:4318 \
  -v $(pwd)/otel-collector-config.yaml:/etc/otelcol/config.yaml \
  otel/opentelemetry-collector:latest
```

**Minimal collector config (`otel-collector-config.yaml`):**

```yaml
receivers:
  otlp:
    protocols:
      http:
        endpoint: 0.0.0.0:4318

exporters:
  debug:
    verbosity: detailed

service:
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [debug]
    metrics:
      receivers: [otlp]
      exporters: [debug]
    logs:
      receivers: [otlp]
      exporters: [debug]
```

**Erlang configuration:**

```erlang
instrument_exporter:register(instrument_exporter_otlp:new(#{
    endpoint => "http://localhost:4318"
})),
instrument_metrics_exporter:register(instrument_metrics_exporter_otlp:new(#{
    endpoint => "http://localhost:4318"
})),
instrument_log_exporter:register(instrument_log_exporter_otlp:new(#{
    endpoint => "http://localhost:4318"
})).
```

### Jaeger

Jaeger natively supports OTLP. Send traces directly to Jaeger's OTLP endpoint.

**Docker Setup:**

```bash
docker run -d --name jaeger \
  -p 4317:4317 \
  -p 4318:4318 \
  -p 16686:16686 \
  jaegertracing/all-in-one:latest
```

**Erlang configuration:**

```erlang
instrument_exporter:register(instrument_exporter_otlp:new(#{
    endpoint => "http://localhost:4318"
})).
```

Access the Jaeger UI at `http://localhost:16686`.

### Grafana Tempo

Tempo is Grafana's distributed tracing backend with native OTLP support.

**Docker Compose Setup:**

```yaml
version: "3"
services:
  tempo:
    image: grafana/tempo:latest
    command: ["-config.file=/etc/tempo.yaml"]
    volumes:
      - ./tempo.yaml:/etc/tempo.yaml
    ports:
      - "4318:4318"   # OTLP HTTP
      - "3200:3200"   # Tempo API

  grafana:
    image: grafana/grafana:latest
    ports:
      - "3000:3000"
    environment:
      - GF_AUTH_ANONYMOUS_ENABLED=true
      - GF_AUTH_ANONYMOUS_ORG_ROLE=Admin
```

**Tempo config (`tempo.yaml`):**

```yaml
server:
  http_listen_port: 3200

distributor:
  receivers:
    otlp:
      protocols:
        http:

storage:
  trace:
    backend: local
    local:
      path: /tmp/tempo/blocks
```

**Erlang configuration:**

```erlang
instrument_exporter:register(instrument_exporter_otlp:new(#{
    endpoint => "http://localhost:4318"
})).
```

### Cloud Backends

Most cloud observability platforms support OTLP. The pattern is similar: provide the endpoint URL and authentication headers.

**Generic OTLP Pattern:**

```erlang
instrument_exporter:register(instrument_exporter_otlp:new(#{
    endpoint => "https://otlp.your-provider.com:4318",
    headers => #{
        <<"Authorization">> => <<"Bearer your-api-key">>,
        <<"X-Custom-Header">> => <<"value">>
    },
    compression => gzip
})).
```

**Datadog (via OTLP):**

```erlang
instrument_exporter:register(instrument_exporter_otlp:new(#{
    endpoint => "https://trace.agent.datadoghq.com:4318",
    headers => #{
        <<"DD-API-KEY">> => <<"your-datadog-api-key">>
    }
})).
```

**Honeycomb:**

```erlang
instrument_exporter:register(instrument_exporter_otlp:new(#{
    endpoint => "https://api.honeycomb.io:443",
    headers => #{
        <<"x-honeycomb-team">> => <<"your-api-key">>,
        <<"x-honeycomb-dataset">> => <<"your-dataset">>
    }
})).
```

**New Relic:**

```erlang
instrument_exporter:register(instrument_exporter_otlp:new(#{
    endpoint => "https://otlp.nr-data.net:4318",
    headers => #{
        <<"api-key">> => <<"your-license-key">>
    }
})).
```

### Environment Variable Configuration

Configure endpoints via environment variables for flexibility across environments:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT="http://otel-collector:4318"
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer token"
```

```erlang
%% Initialize from environment
instrument_config:init().

%% Get configured endpoint
Endpoint = instrument_config:get_otlp_endpoint().
```

## Span Data Structure

Exporters receive spans with the following structure:

```erlang
-record(span_ctx, {
    trace_id :: <<_:128>> | undefined,
    span_id :: <<_:64>> | undefined,
    trace_flags = 1 :: 0 | 1,
    trace_state = [] :: [{binary(), binary()}],
    is_remote = false :: boolean()
}).

-record(span, {
    name :: binary(),
    ctx :: #span_ctx{},
    parent_ctx :: #span_ctx{} | undefined,
    tracer :: #tracer{} | undefined,
    kind = internal :: client | server | producer | consumer | internal,
    start_time :: integer(),                     %% Wall clock, ns
    end_time :: integer() | undefined,
    attributes = #{} :: map(),
    events = [] :: [#span_event{}],
    links = [] :: [#span_link{}],
    status = unset :: unset | ok | {error, binary()},
    is_recording = true :: boolean(),
    dropped_attributes_count = 0 :: non_neg_integer(),
    dropped_events_count = 0 :: non_neg_integer(),
    dropped_links_count = 0 :: non_neg_integer()
}).
```

For events:

```erlang
-record(span_event, {
    name :: binary(),
    timestamp :: integer(),                      %% Wall clock, ns
    attributes = #{} :: map(),
    dropped_attributes_count = 0 :: non_neg_integer()
}).
```

For links:

```erlang
-record(span_link, {
    ctx :: #span_ctx{},
    attributes = #{} :: map(),
    dropped_attributes_count = 0 :: non_neg_integer()
}).
```
