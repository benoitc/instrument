# Benchmarks

Performance benchmarks for the instrument library, measuring throughput of core operations.

## Running Benchmarks

```bash
# Run core benchmarks
./bench/run_bench.escript

# Run real-world scenario benchmarks
rebar3 compile
erl -pa _build/default/lib/*/ebin -noshell -eval \
  "c:c(\"bench/instrument_realworld_bench.erl\"), instrument_realworld_bench:run(), halt()."

# Run client tracing strategy benchmarks
erl -pa _build/default/lib/*/ebin -noshell -eval \
  "c:c(\"bench/instrument_client_bench.erl\"), instrument_client_bench:run(), halt()."
```

## Results

Benchmarks run on Apple M1 Pro, OTP 28, 100,000 iterations per test (April 2026).

### Counter Operations

| Operation | Throughput | Latency |
|-----------|------------|---------|
| `inc_counter/1` | 43.6M ops/sec | 0.023 us/op |
| `inc_counter/2` | 36.4M ops/sec | 0.028 us/op |
| `get_counter/1` | 42.0M ops/sec | 0.024 us/op |

### Gauge Operations

| Operation | Throughput | Latency |
|-----------|------------|---------|
| `set_gauge/2` | 38.1M ops/sec | 0.026 us/op |
| `inc_gauge/1` | 47.6M ops/sec | 0.021 us/op |
| `dec_gauge/1` | 45.8M ops/sec | 0.022 us/op |
| `get_gauge/1` | 41.0M ops/sec | 0.024 us/op |

### Histogram Operations

| Operation | Throughput | Latency |
|-----------|------------|---------|
| `observe/2` | 22.1M ops/sec | 0.045 us/op |
| `get/1` | 3.0M ops/sec | 0.328 us/op |

### OpenTelemetry Meter API

| Operation | Throughput | Latency |
|-----------|------------|---------|
| `meter:add/2` | 65.8M ops/sec | 0.015 us/op |
| `meter:add/3` (with attrs) | 2.8M ops/sec | 0.352 us/op |
| `meter:record/2` | 30.7M ops/sec | 0.033 us/op |
| `meter:record/3` (with attrs) | 3.7M ops/sec | 0.267 us/op |
| `meter:set/2` | 75.2M ops/sec | 0.013 us/op |

### OpenTelemetry Tracer API

| Operation | Throughput | Latency |
|-----------|------------|---------|
| `with_span/2` | 294K ops/sec | 3.40 us/op |
| `with_span/3` (with kind) | 298K ops/sec | 3.36 us/op |
| `with_span` + `set_attributes` | 288K ops/sec | 3.48 us/op |
| `with_span` + `add_event` | 308K ops/sec | 3.25 us/op |
| Nested spans (3 levels) | 184K ops/sec | 5.44 us/op |
| `start_span`/`end_span` | 312K ops/sec | 3.20 us/op |

### OpenTelemetry Logger Integration

| Operation | Throughput | Latency |
|-----------|------------|---------|
| `logger:info` (no span) | 52.8M ops/sec | 0.019 us/op |
| `logger:info` (in span) | 48.2M ops/sec | 0.021 us/op |
| `logger:info` (with metadata) | 46.7M ops/sec | 0.021 us/op |
| `instrument_logger:emit` | 3.2M ops/sec | 0.316 us/op |

## Real-World Scenarios

Simulated production workloads to measure end-to-end performance.

### DB Query Tracing

| Scenario | Throughput | Latency |
|----------|------------|---------|
| DB query traced | 200K ops/sec | 5.01 us/op |
| DB query metrics only | 1.79M ops/sec | 0.56 us/op |

Tracing overhead: ~4.5 us per operation.

### HTTP Request Pipeline

| Scenario | Throughput | Latency |
|----------|------------|---------|
| 3 nested spans (auth + db + response) | 98K ops/sec | 10.2 us/op |
| 1 span only | 189K ops/sec | 5.3 us/op |
| No tracing | 1.60M ops/sec | 0.62 us/op |

### Concurrent Load

- 100 workers x 1,000 requests = 100,000 total
- Result: **27,465 req/sec** sustained throughput

### Memory Impact

- 100,000 spans with attributes and events
- Throughput: **245,700 spans/sec**
- Memory overhead: negligible (GC-friendly design)

## Client Tracing Strategies

Comparing different approaches to instrument client operations (DB, HTTP, etc).

### Strategy Comparison

| Strategy | Throughput | Latency | Notes |
|----------|------------|---------|-------|
| No tracing (baseline) | 442M ops/sec | 0.002 us/op | Reference |
| Manual `with_span` | 249K ops/sec | 4.02 us/op | Direct tracer use |
| `instrument_client:with_span` | 259K ops/sec | 3.86 us/op | Helper (slightly faster) |
| Full options | 249K ops/sec | 4.02 us/op | With target, statement, attrs |
| With sanitization | 94K ops/sec | 10.60 us/op | Regex-based sanitization |

### Sanitization Performance

| Strategy | Throughput | Latency | Notes |
|----------|------------|---------|-------|
| No sanitization | 600M ops/sec | 0.002 us/op | Reference |
| Default (short SQL) | 200K ops/sec | 5.00 us/op | ~60 chars |
| Default (long SQL) | 166K ops/sec | 6.04 us/op | ~200 chars |
| Custom placeholder | 196K ops/sec | 5.10 us/op | User-defined |
| Preserve $N params | 156K ops/sec | 6.42 us/op | Keep $1, $2 placeholders |
| URL path sanitize | 452K ops/sec | 2.21 us/op | Simple pattern match |

### Sampling Strategies

| Strategy | Throughput | Latency | Notes |
|----------|------------|---------|-------|
| always_on (100%) | 284K ops/sec | 3.52 us/op | All spans recorded |
| always_off (0%) | 1.45M ops/sec | 0.69 us/op | Dropped spans are cheap |
| probability (50%) | 410K ops/sec | 2.44 us/op | Half sampled |
| probability (10%) | 847K ops/sec | 1.18 us/op | Low sampling |
| probability (1%) | 1.21M ops/sec | 0.83 us/op | Very low sampling |
| attribute (no rules) | 830K ops/sec | 1.20 us/op | Default ratio only |
| attribute (1 rule) | 409K ops/sec | 2.45 us/op | Single rule match |
| attribute (7 rules) | 1.15M ops/sec | 0.87 us/op | Multiple rules, early exit |

### Trace Context Injection

| Strategy | Throughput | Latency | Notes |
|----------|------------|---------|-------|
| No injection | 428M ops/sec | 0.002 us/op | Reference |
| SQL comment format | 2.15M ops/sec | 0.46 us/op | `/*traceparent=...*/` |
| URL param format | 1.33M ops/sec | 0.75 us/op | `?traceparent=...` |
| Custom format | 2.17M ops/sec | 0.46 us/op | User-defined delimiters |
| format_trace_comment/0 | 2.53M ops/sec | 0.40 us/op | Format only, no append |

### Pool Span Helpers

| Strategy | Throughput | Latency | Notes |
|----------|------------|---------|-------|
| No pool tracking | 243M ops/sec | 0.004 us/op | Reference |
| Manual pool spans | 255K ops/sec | 3.93 us/op | Direct tracer use |
| pool_acquire/release | 258K ops/sec | 3.88 us/op | Helper functions |
| with_pool_span | 230K ops/sec | 4.35 us/op | Wrapped operation |

## Analysis

### Metrics Performance

Counter and gauge operations achieve 38-48 million operations per second thanks to NIF-based atomic operations. The OpenTelemetry Meter API adds minimal overhead for operations without attributes (65-75M ops/sec).

Operations with attributes are slower (2.8-3.7M ops/sec) due to attribute map handling and vec metric creation, but still very fast for most use cases.

### Tracing Performance

Span creation costs ~3.2-3.5 us per span due to:
- Context management (process dictionary operations)
- Span ID generation
- Timestamp collection
- Exporter callbacks

The library achieves ~300K spans/second for simple spans. Nested spans scale sub-linearly: 3 nested spans take ~5.4 us (not 3x single span time) due to context reuse.

### Sampling Impact

Sampling dramatically reduces overhead:
- **always_off**: 5x faster than always_on (dropped spans skip most work)
- **1% sampling**: Nearly as fast as always_off
- **Attribute-based**: Scales well, early exit on rule match

### Optimization Tips

1. **Use sampling in production** - even 10% sampling reduces overhead by 3x
2. **Prefer counters over histograms** when you only need counts
3. **Batch operations** rather than creating many small spans
4. **Pre-create instruments** at startup rather than on-demand
5. **Sanitization adds ~6-7 us** - only use when necessary
6. **Attribute operations are slower** - minimize attribute cardinality
7. **Dropped spans are 5x cheaper** - sampling helps significantly
