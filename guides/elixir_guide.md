# Elixir Users Guide

This guide covers using instrument in Elixir applications, including Elixir-idiomatic patterns and migration from Telemetry.

## Table of Contents

1. [Introduction](#introduction)
2. [Installation](#installation)
3. [Quick Start](#quick-start)
4. [Distributed Tracing](#distributed-tracing)
5. [Cross-Process Context Propagation](#cross-process-context-propagation)
6. [Migrating from Telemetry](#migrating-from-telemetry)
7. [Phoenix Integration](#phoenix-integration)
8. [Testing](#testing)

## Introduction

`instrument` is an OpenTelemetry-compatible observability library written in Erlang. Since Elixir runs on the BEAM, you can call instrument directly from Elixir using Erlang module syntax (`:module_name`).

Key features for Elixir developers:

- Native BEAM integration with process dictionary context
- OpenTelemetry Meter and Tracer APIs
- W3C TraceContext and B3 propagation
- Direct Prometheus export
- Built-in test assertions

## Installation

### mix.exs

Add instrument to your dependencies:

```elixir
def deps do
  [
    {:instrument, "~> 0.3.0"}
  ]
end
```

### Application Configuration

Configure instrument in `config/config.exs`:

```elixir
config :instrument,
  service_name: "my_elixir_service",
  sampler: {:instrument_sampler_probability, %{ratio: 0.1}}
```

Or use environment variables (recommended for production):

```elixir
# config/runtime.exs
config :instrument,
  service_name: System.get_env("OTEL_SERVICE_NAME", "my_service")
```

Common environment variables:

| Variable | Description |
|----------|-------------|
| `OTEL_SERVICE_NAME` | Service name for resource |
| `OTEL_TRACES_SAMPLER` | Sampler type (always_on, traceidratio, etc.) |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | OTLP endpoint URL |
| `OTEL_PROPAGATORS` | Propagators (tracecontext, b3, b3multi) |

## Quick Start

### Counter

```elixir
# Create a counter
counter = :instrument.new_counter(:http_requests_total, "Total HTTP requests")

# Increment
:instrument.inc_counter(counter)
:instrument.inc_counter(counter, 5)

# Get value
value = :instrument.get_counter(counter)  # 6.0
```

### Gauge

```elixir
# Create a gauge
gauge = :instrument.new_gauge(:active_connections, "Active connections")

# Set value
:instrument.set_gauge(gauge, 100)

# Increment/decrement
:instrument.inc_gauge(gauge)       # 101
:instrument.dec_gauge(gauge, 5)    # 96

# Get value
value = :instrument.get_gauge(gauge)
```

### Histogram

```elixir
# Create with default buckets
histogram = :instrument.new_histogram(:request_duration_seconds, "Request duration")

# Create with custom buckets
histogram = :instrument.new_histogram(
  :response_size_bytes,
  "Response size",
  [100, 500, 1000, 5000, 10000]
)

# Record observations
:instrument.observe_histogram(histogram, 0.125)

# Get distribution
%{count: count, sum: sum, buckets: buckets} = :instrument.get_histogram(histogram)
```

### OpenTelemetry Meter API

For labeled metrics with attributes:

```elixir
# Get a meter for your service
meter = :instrument_meter.get_meter("my_service")

# Create instruments
counter = :instrument_meter.create_counter(meter, "http_requests_total", %{
  description: "Total HTTP requests",
  unit: "1"
})

histogram = :instrument_meter.create_histogram(meter, "http_request_duration_seconds", %{
  description: "Request duration",
  unit: "s"
})

# Record with attributes (dimensions)
:instrument_meter.add(counter, 1, %{method: "GET", status: 200})
:instrument_meter.record(histogram, 0.125, %{endpoint: "/api/users"})
```

## Distributed Tracing

### Creating Spans

```elixir
defmodule MyApp.Orders do
  def process_order(order) do
    :instrument_tracer.with_span("process_order", %{kind: :server}, fn ->
      # Add attributes for filtering and querying in your backend
      :instrument_tracer.set_attributes(%{
        "order.id" => order.id,
        "customer.id" => order.customer_id,
        "order.total" => order.total
      })

      # Add events for important moments
      :instrument_tracer.add_event("order_validated")

      result = do_process(order)

      # Set status
      :instrument_tracer.set_status(:ok)
      result
    end)
  end
end
```

### Nested Spans

```elixir
def handle_request(request) do
  :instrument_tracer.with_span("handle_request", fn ->
    # Child spans automatically link to parent
    :instrument_tracer.with_span("validate_input", fn ->
      validate(request)
    end)

    :instrument_tracer.with_span("process_data", fn ->
      process(request)
    end)

    :instrument_tracer.with_span("send_response", fn ->
      send_response()
    end)
  end)
end
```

### Error Handling

```elixir
def risky_operation(data) do
  :instrument_tracer.with_span("risky_operation", fn ->
    try do
      dangerous_work(data)
    rescue
      e ->
        :instrument_tracer.set_status(:error, Exception.message(e))
        :instrument_tracer.add_event("exception", %{
          "exception.type" => inspect(e.__struct__),
          "exception.message" => Exception.message(e)
        })
        reraise e, __STACKTRACE__
    end
  end)
end
```

### Span Options

```elixir
# Server span (incoming request)
:instrument_tracer.with_span("api_request", %{kind: :server}, fn -> ... end)

# Client span (outgoing request)
:instrument_tracer.with_span("db_query", %{kind: :client}, fn -> ... end)

# Internal span (within a service)
:instrument_tracer.with_span("compute", %{kind: :internal}, fn -> ... end)
```

## Cross-Process Context Propagation

### Using instrument_propagation.spawn

Spawn a process with trace context automatically propagated:

```elixir
def start_background_work do
  :instrument_tracer.with_span("initiate_work", fn ->
    # Spawned process inherits trace context
    :instrument_propagation.spawn(fn ->
      :instrument_tracer.with_span("background_work", fn ->
        # This span is a child of "initiate_work"
        do_background_work()
      end)
    end)
  end)
end
```

### Task.async with Context Propagation

For Elixir's Task module, capture and attach context manually:

```elixir
def parallel_operations(items) do
  :instrument_tracer.with_span("parallel_processing", fn ->
    # Capture current context BEFORE creating tasks
    ctx = :instrument_context.current()

    tasks =
      Enum.map(items, fn item ->
        Task.async(fn ->
          # Attach context in the task process
          token = :instrument_context.attach(ctx)
          try do
            :instrument_tracer.with_span("process_item", fn ->
              :instrument_tracer.set_attribute("item.id", item.id)
              process_item(item)
            end)
          after
            :instrument_context.detach(token)
          end
        end)
      end)

    Task.await_many(tasks)
  end)
end
```

### GenServer Integration

Pass context with GenServer calls using the provided helpers:

```elixir
# Client side - use call_with_context
def get_data(server, key) do
  :instrument_propagation.call_with_context(server, {:get, key})
end

def update_data(server, key, value) do
  :instrument_propagation.cast_with_context(server, {:update, key, value})
end
```

```elixir
# Server side - handle wrapped messages
defmodule MyApp.DataServer do
  use GenServer

  def handle_call({:"$instrument_call", ctx, request}, from, state) do
    token = :instrument_context.attach(ctx)
    try do
      handle_call(request, from, state)
    after
      :instrument_context.detach(token)
    end
  end

  def handle_call({:get, key}, _from, state) do
    :instrument_tracer.with_span("data_server.get", fn ->
      :instrument_tracer.set_attribute("key", key)
      {:reply, Map.get(state, key), state}
    end)
  end

  def handle_cast({:"$instrument_cast", ctx, msg}, state) do
    token = :instrument_context.attach(ctx)
    try do
      handle_cast(msg, state)
    after
      :instrument_context.detach(token)
    end
  end

  def handle_cast({:update, key, value}, state) do
    :instrument_tracer.with_span("data_server.update", fn ->
      :instrument_tracer.set_attributes(%{"key" => key})
      {:noreply, Map.put(state, key, value)}
    end)
  end
end
```

### Manual Context Passing

For custom process patterns:

```elixir
defmodule MyApp.Worker do
  def start_with_context(work) do
    ctx = :instrument_context.current()

    spawn(fn ->
      token = :instrument_context.attach(ctx)
      try do
        :instrument_tracer.with_span("worker.execute", fn ->
          execute(work)
        end)
      after
        :instrument_context.detach(token)
      end
    end)
  end

  # With spawn_link
  def start_linked_with_context(work) do
    ctx = :instrument_context.current()

    spawn_link(fn ->
      token = :instrument_context.attach(ctx)
      try do
        execute(work)
      after
        :instrument_context.detach(token)
      end
    end)
  end
end
```

### HTTP Header Propagation

Inject and extract trace context from HTTP headers:

```elixir
# Inject into outgoing request
def make_request(url, body) do
  :instrument_tracer.with_span("http_request", %{kind: :client}, fn ->
    headers = :instrument_propagation.inject_headers(:instrument_context.current())

    # headers is a list of tuples like:
    # [{"traceparent", "00-abc123..."}, {"tracestate", "..."}]

    HTTPoison.post(url, body, headers)
  end)
end

# Extract from incoming request
def handle_incoming(conn) do
  headers = Enum.map(conn.req_headers, fn {k, v} -> {k, v} end)
  ctx = :instrument_propagation.extract_headers(headers)
  token = :instrument_context.attach(ctx)

  try do
    :instrument_tracer.with_span("handle_request", %{kind: :server}, fn ->
      process_request(conn)
    end)
  after
    :instrument_context.detach(token)
  end
end
```

## Migrating from Telemetry

### Concept Mapping

| Telemetry | instrument |
|-----------|------------|
| `:telemetry.execute/3` | `:instrument_meter.add/2,3` |
| `:telemetry.span/3` | `:instrument_tracer.with_span/2,3` |
| `:telemetry.attach/4` | Exporters (OTLP, Prometheus) |
| `Telemetry.Metrics.counter/2` | `:instrument_meter.create_counter/3` |
| `Telemetry.Metrics.last_value/2` | `:instrument_meter.create_gauge/3` |
| `Telemetry.Metrics.distribution/2` | `:instrument_meter.create_histogram/3` |

### Counter Migration

**Before (Telemetry):**

```elixir
# Emitting
:telemetry.execute([:my_app, :request], %{count: 1}, %{method: "GET", status: 200})

# Handling
:telemetry.attach("request-counter", [:my_app, :request], fn _name, measurements, metadata, _config ->
  forward_to_monitoring(measurements, metadata)
end, nil)
```

**After (instrument):**

```elixir
# Setup (once at application start)
meter = :instrument_meter.get_meter("my_app")
counter = :instrument_meter.create_counter(meter, "my_app_requests_total", %{
  description: "Total requests"
})

# Record
:instrument_meter.add(counter, 1, %{method: "GET", status: 200})

# Export happens automatically via configured exporters
```

### Span Migration

**Before (Telemetry):**

```elixir
:telemetry.span([:my_app, :process], %{id: id}, fn ->
  result = do_work()
  {result, %{result: :ok}}
end)
```

**After (instrument):**

```elixir
:instrument_tracer.with_span("my_app.process", fn ->
  :instrument_tracer.set_attribute("id", id)
  result = do_work()
  :instrument_tracer.set_status(:ok)
  result
end)
```

### Handler Migration

Telemetry handlers forward metrics to backends. With instrument, configure exporters instead:

**Before (Telemetry):**

```elixir
# Using telemetry_metrics_prometheus
Telemetry.Metrics.counter("http.request.count", tags: [:method, :status])

# Handler collects and exposes metrics
TelemetryMetricsPrometheus.init(metrics: metrics)
```

**After (instrument):**

```elixir
# Metrics are exported automatically
# Expose Prometheus endpoint in your router:
get "/metrics" do
  body = :instrument_prometheus.format()
  content_type = :instrument_prometheus.content_type()

  conn
  |> put_resp_content_type(content_type)
  |> send_resp(200, body)
end
```

### Complete Migration Example

**Before:**

```elixir
defmodule MyApp.Orders do
  def create_order(params) do
    :telemetry.span([:my_app, :orders, :create], %{}, fn ->
      result = do_create_order(params)
      {result, %{status: :ok, order_id: result.id}}
    end)
  end
end

# In application.ex
def start(_type, _args) do
  :telemetry.attach_many(
    "order-metrics",
    [[:my_app, :orders, :create, :stop]],
    &handle_event/4,
    nil
  )
end
```

**After:**

```elixir
defmodule MyApp.Orders do
  def create_order(params) do
    :instrument_tracer.with_span("orders.create", %{kind: :server}, fn ->
      :instrument_tracer.set_attribute("customer.id", params.customer_id)

      result = do_create_order(params)

      :instrument_tracer.set_attributes(%{
        "order.id" => result.id,
        "order.total" => result.total
      })
      :instrument_tracer.set_status(:ok)
      result
    end)
  end
end

# Metrics via OTel Meter API
defmodule MyApp.Metrics do
  def setup do
    meter = :instrument_meter.get_meter("my_app")

    counter = :instrument_meter.create_counter(meter, "orders_created_total", %{
      description: "Total orders created"
    })

    :persistent_term.put(:orders_counter, counter)
  end

  def record_order_created(order) do
    counter = :persistent_term.get(:orders_counter)
    :instrument_meter.add(counter, 1, %{
      customer_tier: order.customer.tier
    })
  end
end
```

## Phoenix Integration

### Plug for Trace Context Extraction

```elixir
defmodule MyAppWeb.Plugs.TraceContext do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    # Extract trace context from headers
    headers = Enum.map(conn.req_headers, fn {k, v} -> {k, v} end)
    ctx = :instrument_propagation.extract_headers(headers)
    token = :instrument_context.attach(ctx)

    # Store token for cleanup
    conn = assign(conn, :instrument_token, token)

    # Register callback to detach context
    register_before_send(conn, fn conn ->
      if token = conn.assigns[:instrument_token] do
        :instrument_context.detach(token)
      end
      conn
    end)
  end
end
```

### Instrumenting Controllers

```elixir
defmodule MyAppWeb.OrderController do
  use MyAppWeb, :controller

  def create(conn, params) do
    :instrument_tracer.with_span("orders.create", %{kind: :server}, fn ->
      :instrument_tracer.set_attributes(%{
        "http.method" => "POST",
        "http.route" => "/orders"
      })

      case Orders.create_order(params) do
        {:ok, order} ->
          :instrument_tracer.set_attributes(%{
            "http.status_code" => 201,
            "order.id" => order.id
          })
          :instrument_tracer.set_status(:ok)

          conn
          |> put_status(:created)
          |> render(:show, order: order)

        {:error, changeset} ->
          :instrument_tracer.set_attributes(%{
            "http.status_code" => 422
          })
          :instrument_tracer.set_status(:error, "validation_failed")

          conn
          |> put_status(:unprocessable_entity)
          |> render(:error, changeset: changeset)
      end
    end)
  end
end
```

### Router-Level Instrumentation

```elixir
defmodule MyAppWeb.Router do
  use MyAppWeb, :router

  pipeline :instrumented do
    plug MyAppWeb.Plugs.TraceContext
  end

  scope "/api", MyAppWeb do
    pipe_through [:api, :instrumented]

    resources "/orders", OrderController
  end
end
```

### LiveView Considerations

For LiveView, instrument at mount and handle_event:

```elixir
defmodule MyAppWeb.OrderLive do
  use MyAppWeb, :live_view

  def mount(_params, session, socket) do
    :instrument_tracer.with_span("order_live.mount", fn ->
      orders = Orders.list_orders()
      :instrument_tracer.set_attribute("orders.count", length(orders))
      {:ok, assign(socket, orders: orders)}
    end)
  end

  def handle_event("delete", %{"id" => id}, socket) do
    :instrument_tracer.with_span("order_live.delete", fn ->
      :instrument_tracer.set_attribute("order.id", id)
      Orders.delete_order(id)
      :instrument_tracer.set_status(:ok)
      {:noreply, assign(socket, orders: Orders.list_orders())}
    end)
  end
end
```

## Testing

### ExUnit Setup

```elixir
defmodule MyApp.InstrumentedTest do
  use ExUnit.Case

  setup do
    :instrument_test.setup()

    on_exit(fn ->
      :instrument_test.cleanup()
    end)

    :ok
  end

  setup do
    :instrument_test.reset()
    :ok
  end
end
```

### Testing Spans

```elixir
defmodule MyApp.OrdersTest do
  use ExUnit.Case

  setup do
    :instrument_test.setup()
    on_exit(fn -> :instrument_test.cleanup() end)
    :instrument_test.reset()
    :ok
  end

  test "create_order creates span with attributes" do
    order = MyApp.Orders.create_order(%{customer_id: 123, total: 99.99})

    # Assert span was created
    :instrument_test.assert_span_exists("orders.create")

    # Assert attributes
    :instrument_test.assert_span_attribute("orders.create", "customer.id", 123)
    :instrument_test.assert_span_attribute("orders.create", "order.id", order.id)

    # Assert status
    :instrument_test.assert_span_status("orders.create", :ok)
  end

  test "nested spans have parent-child relationship" do
    MyApp.Orders.process_with_validation(%{id: 1})

    :instrument_test.assert_span_exists("orders.process")
    :instrument_test.assert_span_exists("orders.validate")
    :instrument_test.assert_parent_child("orders.process", "orders.validate")
  end
end
```

### Testing Metrics

```elixir
test "counter increments on order creation" do
  :instrument_test.reset()

  MyApp.Orders.create_order(%{customer_id: 1})
  MyApp.Orders.create_order(%{customer_id: 2})

  :instrument_test.assert_counter(:orders_created_total, 2.0)
end

test "gauge tracks active orders" do
  :instrument_test.reset()

  MyApp.Orders.set_active_count(42)

  :instrument_test.assert_gauge(:active_orders, 42.0)
end
```

### Testing Async Operations

```elixir
test "async operations propagate trace context" do
  parent = self()

  :instrument_tracer.with_span("parent", fn ->
    parent_trace_id = :instrument_tracer.trace_id()

    :instrument_propagation.spawn(fn ->
      :instrument_tracer.with_span("child", fn ->
        child_trace_id = :instrument_tracer.trace_id()
        send(parent, {:trace_id, child_trace_id})
      end)
    end)

    receive do
      {:trace_id, ^parent_trace_id} -> :ok
    after
      1000 -> flunk("Trace ID mismatch or timeout")
    end
  end)

  # Wait for spans to be collected
  :ok = :instrument_test.wait_for_spans(2, 1000)

  :instrument_test.assert_span_exists("parent")
  :instrument_test.assert_span_exists("child")
end
```

### Test Helper Module

Create a shared test helper:

```elixir
defmodule MyApp.InstrumentCase do
  use ExUnit.CaseTemplate

  setup do
    :instrument_test.setup()

    on_exit(fn ->
      :instrument_test.cleanup()
    end)

    :ok
  end

  setup do
    :instrument_test.reset()
    :ok
  end
end
```

Use in tests:

```elixir
defmodule MyApp.SomeTest do
  use MyApp.InstrumentCase

  test "my instrumented code" do
    # test body
  end
end
```

---

## Next Steps

- [Getting Started Guide](getting_started.md) for Erlang examples
- [Context Propagation Guide](context_propagation.md) for advanced patterns
- [Exporters Guide](exporters.md) for OTLP and Prometheus setup
- [Testing Instrumentation](testing_instrumentation.md) for more test patterns
