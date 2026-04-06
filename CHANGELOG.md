# Changelog

All notable changes to this project will be documented in this file.

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
