# Changelog

All notable changes to this project will be documented in this file.

## [0.6.1] - 2026-04-16

### Fixed
- Moved hex package `files` list from `rebar.config` to `instrument.app.src` so `do_build.sh`, `do_cmake.sh`, and `c_src/` build assets are actually shipped in the published tarball (the rebar.config `{hex, [{files, ...}]}` entry was silently ignored for non-standard files)
- ex_doc XML parse errors caused by `<<...>>` literals and comparison operators in doc comments

## [0.6.0] - 2026-04-16

### Changed
- Renamed `instrument` module to `instrument_metric` to avoid conflict with Erlang's `runtime_tools` instrument module
- Bumped application version in `instrument.app.src` to 0.6.0

## [0.5.0] - 2026-04-08

### Added
- OTel spec compliance features: span limits, dropped counts tracking, exemplar support
- B3 ParentSpanId injection for nested spans
- Aggregation temporality support (cumulative/delta)
- Observable instrument 1-arity callbacks with attributes
- Tests for OTel spec compliance (30 new test cases)
- Throughput optimizations for exporter and processor lookup
- Updated benchmarks documentation

### Fixed
- Spawned-child trace leak with session-based cleanup
- OpenTelemetry spec compliance issues in OTLP export
- Preserved tracer scope in OTLP span export

## [0.4.0] - 2026-04-07

### Added
- Tail-based sampling span processor
- Generic client tracing utilities and attribute-based sampling
- Flight recorder using erl_tracer NIF for low-overhead message tracing
- Global tracing enable flag for performance optimization
- Custom span_id support to tracer API
- `instrument_test` module for validating instrumentation
- `startTimeUnixNano` to OTLP metrics export
- Debug logging to broad exception handlers
- Error logging to span processor callbacks
- Benchmarks for OpenTelemetry APIs and client tracing strategies
- Design and internals documentation
- Book chapters and reference guides
- Elixir users guide
- Runnable cross-process tracing and logging examples
- Tests for metric names and attributes in exporter
- Tests for tracing disabled and custom span_id
- Regression tests for 4 bug fixes (record_only sampling, metric description/unit, histogram view boundaries, OTLP scope config)

### Fixed
- Critical tracing and OTLP spec compliance issues
- Histogram and OTLP spec compliance issues
- Empty bucket validation crash in histogram
- Tuple metric name handling for OTEL metrics
- Race condition in tracer exporter list
- Race condition in metric index updates
- Vec metric cleanup and concurrent attribute race condition
- `mark/1,2` not working in spawned child processes
- erl_tracer issues: teardown, idempotency, async parent spans
- Multiple bugs in client and tail sampler
- 5 bugs in span processors, metrics, and context propagation
- 5 client tracing issues
- Test failures in metrics exporter and span processor
- E2E test skip behavior and timing issues

### Changed
- Replaced seq_trace with erl_tracer NIF for flight recorder performance
- Improved flight recorder eviction performance
- Improved config auto-registration and processor shutdown handling
- Improved edge case handling in tail sampler
- Renamed exporter callbacks to avoid gen_server conflicts
- Added xref checks
- Documented processor callback restrictions
- Filter internal tracer bootstrap messages in trace_receive

## [0.3.0] - 2026-04-01

### Added
- OpenTelemetry-compatible API with native implementation
- Context propagation via `instrument_context` module
- W3C TraceContext format support in `instrument_propagation`
- W3C Baggage propagation via `instrument_baggage` module
- B3 single-header propagator (`instrument_propagator_b3`) for Zipkin compatibility
- B3 multi-header propagator (`instrument_propagator_b3_multi`) for X-B3-* headers
- Support for `b3` and `b3multi` in `OTEL_PROPAGATORS` environment variable
- Native span implementation via `instrument_tracer` with full lifecycle management
- OTel-compatible MeterProvider/Meter API via `instrument_meter`
- Attribute handling via `instrument_attributes`
- Erlang logger integration via `instrument_logger` with automatic trace correlation
- Trace/Span ID generation per W3C spec via `instrument_id`
- Span exporter system via `instrument_exporter` with batch processing
- Console exporter (`instrument_exporter_console`) with text and JSON formats
- OTLP HTTP exporter (`instrument_exporter_otlp`) for OpenTelemetry collectors
- Cross-process context propagation helpers
- New test suites for context, tracer, meter, and exporter modules
- New `instrument_otel.hrl` header with OTel record definitions
- Documentation guides: getting started, instrumentation, context propagation, exporters
- E2E tests with Docker (Prometheus + Jaeger)
- Stress tests and race condition tests
- OpenTelemetry compatibility info to README
- Sampling and processing guide, external collectors documentation

### Fixed
- Context/memory leaks with instrument cleanup

### Changed
- Extended `metric` record with OTel fields (description, unit, meter, attributes)
- Updated application description to mention OpenTelemetry support
- Added hackney 3.2.1 as dependency for OTLP HTTP export
- Documentation updates for B3 propagation and OTel clarity

## [0.2.0] - 2026-03-31

### Added
- Vec API for labeled metrics (prometheus-cpp style): `new_counter_vec/3`, `new_gauge_vec/3`, `new_histogram_vec/3`
- Direct vec operations: `inc_counter_vec/2,3`, `get_counter_vec/2`, `inc_gauge_vec/2,3`, `dec_gauge_vec/2,3`, `set_gauge_vec/3`, `get_gauge_vec/2`, `observe_histogram_vec/3`, `get_histogram_vec/2`
- `labels/2` function to get labeled metric instances
- Prometheus text format export via `instrument_prometheus:format/0`
- GitHub Actions CI for OTP 26/27 on Linux and macOS
- ex_doc documentation support
- Type specs for prometheus, vector, and registry modules

### Changed
- Modernized NIF code from C++ to C11 with CMake build system
- Updated README with examples and API documentation
- Updated copyright to 2017-2026

## [0.1.0] - 2017-04-28

### Added
- Initial release
- Counter metrics with `new_counter/2`, `inc_counter/1,2`, `get_counter/1`
- Gauge metrics with `new_gauge/2`, `inc_gauge/1,2`, `dec_gauge/1,2`, `set_gauge/2`, `get_gauge/1`
- Histogram metrics with `new_histogram/2,3`, `observe_histogram/2`, `get_histogram/1`
- Vector support for labeled metrics
- NIF-based implementation for high performance
