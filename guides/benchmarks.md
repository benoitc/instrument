# Benchmarks

Performance benchmarks for the instrument library, measuring throughput of core operations.

## Running Benchmarks

```bash
# Compile and run all benchmarks
rebar3 as bench compile && ./bench/run_bench.escript

# Run specific benchmark suite
./bench/run_bench.escript counter
./bench/run_bench.escript gauge
./bench/run_bench.escript histogram
./bench/run_bench.escript meter
./bench/run_bench.escript tracer
./bench/run_bench.escript logger
```

## Results

Benchmarks run on Apple M1 Pro, OTP 28, 100,000 iterations per test.

### Counter Operations

| Operation | Throughput | Latency |
|-----------|------------|---------|
| `inc_counter/1` | 44M ops/sec | 0.023 us/op |
| `inc_counter/2` | 36M ops/sec | 0.028 us/op |
| `get_counter/1` | 38M ops/sec | 0.026 us/op |

### Gauge Operations

| Operation | Throughput | Latency |
|-----------|------------|---------|
| `set_gauge/2` | 36M ops/sec | 0.028 us/op |
| `inc_gauge/1` | 44M ops/sec | 0.023 us/op |
| `dec_gauge/1` | 43M ops/sec | 0.023 us/op |
| `get_gauge/1` | 40M ops/sec | 0.025 us/op |

### Histogram Operations

| Operation | Throughput | Latency |
|-----------|------------|---------|
| `observe/2` | 23M ops/sec | 0.044 us/op |
| `get/1` | 3.4M ops/sec | 0.293 us/op |

### OpenTelemetry Meter API

| Operation | Throughput | Latency |
|-----------|------------|---------|
| `meter:add/2` | 63M ops/sec | 0.016 us/op |
| `meter:add/3` (with attrs) | 69M ops/sec | 0.015 us/op |
| `meter:record/2` | 30M ops/sec | 0.034 us/op |
| `meter:record/3` (with attrs) | 28M ops/sec | 0.035 us/op |
| `meter:set/2` | 70M ops/sec | 0.014 us/op |

### OpenTelemetry Tracer API

| Operation | Throughput | Latency |
|-----------|------------|---------|
| `with_span/2` | 413K ops/sec | 2.42 us/op |
| `with_span/3` (with kind) | 440K ops/sec | 2.27 us/op |
| `with_span` + `set_attributes` | 440K ops/sec | 2.27 us/op |
| `with_span` + `add_event` | 413K ops/sec | 2.42 us/op |
| Nested spans (3 levels) | 148K ops/sec | 6.74 us/op |
| `start_span`/`end_span` | 437K ops/sec | 2.29 us/op |

### OpenTelemetry Logger Integration

| Operation | Throughput | Latency |
|-----------|------------|---------|
| `logger:info` (no span) | 51M ops/sec | 0.020 us/op |
| `logger:info` (in span) | 54M ops/sec | 0.019 us/op |
| `logger:info` (with metadata) | 49M ops/sec | 0.020 us/op |
| `instrument_logger:emit` | 3.6M ops/sec | 0.280 us/op |

## Analysis

### Metrics Performance

Counter and gauge operations are extremely fast at 36-44 million operations per second, thanks to the NIF-based implementation using atomic operations. The OpenTelemetry Meter API adds minimal overhead, achieving 63-70 million ops/sec for counter and gauge operations.

Histogram operations are slightly slower due to bucket management, but still achieve 23 million observations per second.

### Tracing Performance

Span creation is more expensive than metric operations due to:
- Context management (process dictionary operations)
- Span ID generation
- Timestamp collection
- Exporter callbacks

Despite this, instrument achieves ~400K spans/second for simple spans, which is sufficient for most applications. Nested spans scale linearly - 3 nested spans take approximately 3x the time of a single span.

### Logger Performance

The logger integration adds minimal overhead. When trace context enrichment is enabled, logs inside spans are actually slightly faster due to context caching. The `instrument_logger:emit` function is slower because it creates a full OTel log record structure.

## Optimization Tips

1. **Prefer counters over histograms** when you only need counts
2. **Batch span operations** when possible rather than creating many small spans
3. **Use sampling** in production to reduce tracing overhead
4. **Pre-create instruments** at application startup rather than on-demand
