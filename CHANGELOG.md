# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
- In-place upgrade from 1.1.x self-cleans legacy `persistent_term` shapes
  (`instrument_metrics`, `otel_instrument_vecs`, `instrument_label_overflow`,
  `otel_instruments`) on the first registry (re)start.

### Changed
- Attributed meter data now exports under the registered instrument name as
  one family. Heterogeneous attribute key-sets render with a per-scrape union
  of all label names; columns absent from a given row emit an empty string.
  Derived `<name>_<labels>` families and the `[a_b]` / `[a,b]` label-name
  collision cease to exist.
- Meter instruments appear on first write, not on creation. The constant-zero
  phantom series is gone. Simple-API metrics (`new_counter/2`, `new_gauge/2`,
  `new_histogram/2,3`) still render from creation — that is the expected
  behavior for the explicit Prometheus-style API.
- The cardinality cap is now enforced **per family** (per logical metric name)
  instead of per label-name key-set. A meter family's overflow series carries
  the OTel reserved attribute `otel.metric.overflow=true`; a vec family's
  overflow series carries the declared label names with every value set to
  `<<"otel.metric.overflow">>`. Dropped counts accumulate via
  `instrument_registry:cardinality_dropped/1`.
- OTLP labeled counter and histogram data points now include
  `startTimeUnixNano` (the row's first-write time). It was previously omitted
  on the labeled path.
- OTLP unit resolution now uses the real instrument name. The previous
  suffix-stripping heuristic (removing `_total`, `_bucket`, etc.) is gone.
- `instrument_prometheus:format/0` now runs observable callbacks before
  collecting series data. This removes a stale-observable hazard in
  Prometheus-only deployments (previously the callbacks were only run by the
  OTLP exporter).
- `instrument_registry:lookup/1` now returns the family metadata map for
  series-store-backed names instead of a registered `#metric{}` record. This
  is a breaking change to a semi-public API; only users who inspect the
  `#metric` record fields (rather than treating the return as an opaque
  handle) are affected.
- The vec API (`new_counter_vec`/`inc_counter_vec`/`labels/2`/…) and the
  legacy `instrument_vector` labeled-metric API now share the series store
  with the meter and simple APIs. The fixed-schema container record and its
  per-key-set storage are gone; a label set is resolved by its raw values list
  (the hot-path cache key) with the canonical identity computed only on first
  touch.
- The registry gen_server no longer participates in instrument creation,
  label-set creation, or collection; it serializes only destructive operations
  (unregister, remove_label, clear_labels, unregister_all).
- **Accepted regression:** the meter's unlabeled write (e.g. `add(Counter, N)`
  with no attributes) now costs one `persistent_term:get/1` it did not pay
  before (~+10 ns on a ~15 ns baseline). This is the price of the phantom kill
  (no storage in descriptors means nothing exists before the first write) and
  of stale-proof descriptors that carry identity rather than a live cell
  reference. Compensations: the labeled path — the common case in OTel usage —
  is faster (one `persistent_term` get instead of two plus a per-write binary
  construction for the derived name); simple-API records are direct NIF, as
  before; a future bound-handle API (`bind(Instrument, Attrs) -> BoundRow`) can
  restore the direct-NIF floor for any hot series.

### Fixed
- Unlabeled negative `add/2` on an `up_down_counter` was silently dropped.
  The unlabeled path sent the value to the C NIF `inc` function, which has a
  `Val >= 0` guard; negative deltas returned an error that callers ignored.
  The sign split to `inc_gauge` / `dec_gauge` now applies on all paths.
- `instrument_vector:with_label/4` (and `instrument_metric:with_label/4`) no
  longer drops its value argument on the **first** write of a label set. It
  previously recursed into the 3-arity form on first touch, defaulting the
  increment to 1; the closure now carries the value through, so a fresh label
  set incremented by N reads back as N.
- Map-based attribute label resolution now uses the declared label order (vec
  API) rather than the arbitrary iteration order of the map.
- Collectorless registered records (those registered via `instrument_registry:
  register/1` without a `collect` MFA) no longer crash `collect_all/0`.

### Removed
- Per-scheduler registry replica ETS tables (`instrument_registry_1..N`) and
  the `instrument_lib:table/0,1` clause ladder. Read traffic moved to
  `persistent_term`.
- `instrument_metrics` `persistent_term` index list and the
  `{instrument_metric, Name}` per-name shape. Replaced by the series store's
  computable key space.
- `{otel_instrument_vecs, Base}` and `{instrument_label_overflow, Name}`
  `persistent_term` shapes.
- `otel_instruments` `persistent_term` list. `instrument_meter:list_instruments/0`
  now walks the family chain filtering `{otel, _}` names.
- `#vector{}` record and all code paths that stored labeled series inside
  container records (per-key-set `labels_map`, derived-name creation,
  per-key-set `persistent_term` replace on every new label set).

### Upgrade note
Observable callbacks must not call `instrument_prometheus:format/0` or the
OTLP exporter directly. Those functions now invoke observable callbacks
themselves before collecting; a callback that calls back into the exporter
creates unbounded recursion.

## [1.1.3] - 2026-05-28

### Fixed
- OTP 29 compatibility: replaced the deprecated prefix `catch` operator
  with `try ... catch ... end` throughout `src/` and `test/`. Under OTP 29
  the prefix form emits a deprecation warning, which `warnings_as_errors`
  turned into a build failure.

### Changed
- CI now builds and runs the test suite on OTP 29, alongside OTP 27 and 28.
- Bumped the `meck` test dependency to 1.2.0. Older versions use the
  deprecated prefix `catch` in their own source and fail to compile on
  OTP 29.

## [1.1.2] - 2026-05-25

### Fixed
- A registry restart no longer silently drops previously-created OTel
  instruments. `instrument_registry:init/1` recreated the ETS tables empty
  and reset the `instrument_metrics` index to `[]`, but left the per-name
  `persistent_term` entries behind. The surviving `{otel_instrument, Name}`
  made `instrument_meter:get_instrument/1` return a stale record, so
  `create_counter` / `create_up_down_counter` / `create_histogram`
  short-circuited and never re-registered the underlying metric, while the
  index stayed empty — the metric vanished from `collect_all/0` and the
  Prometheus export even though `add`/`record` kept succeeding. `init/1` now
  erases the stale `otel_instrument`, `otel_instruments`, `instrument_metric`,
  `instrument_label`, and `instrument_label_overflow` entries, so
  `get_instrument/1` returns `undefined` after a restart and the metric
  self-heals on the next `create_*`. `unregister_all` clears the same set
  (it previously missed `otel_instrument` / `otel_instruments`).

## [1.1.1] - 2026-05-16

### Fixed
- `observable_counter` instruments now render as Prometheus `counter`
  with the `_total` suffix instead of `gauge`, in both unlabeled and
  labeled exposition. Previously `create_observable_instrument/3`
  hardcoded gauge-shaped underlying storage and the labeled write path
  tagged the vec as `gauge`, so tooling that relies on `# TYPE … counter`
  to decide rate-ability (Grafana, `rate()`, alerting rules) saw the
  wrong type.
- `instrument_meter:add/3` on a labeled `up_down_counter` no longer
  crashes on negative deltas. The labeled write path previously hardcoded
  counter-shaped vec storage and hit `instrument_counter:inc_counter/2`'s
  `Val >= 0` guard. It now routes through gauge-shaped vec storage with
  a sign split, so `add(Instrument, -1, #{label => ...})` decrements the
  per-label-set value.

## [1.1.0] - 2026-05-11

### Changed
- Histogram bucket counts and the running sum are now backed by a single
  OTP `atomics' array per histogram (slot 1 = IEEE-754 bits of the sum
  via CAS retry, slots 2..N+2 = signed int64 bucket counts via
  `atomics:add/3'). Drops the per-bucket NIF resources and makes
  `get_histogram' / `collect' ~1.5x faster; `observe_histogram' is
  unchanged. Counters, gauges, and up-down counters remain on the NIF
  path.
- Histogram `count' and per-bucket `count' fields in the collected map
  are now integers, matching the `instrument_metrics_exporter' spec
  which already declared them as `integer()'. Callers that compared
  these fields with `=:=' against `float()' values must update their
  expectations.

### Added
- `instrument_atomics' module: thin wrapper over `atomics' providing
  signed-integer slots and IEEE-754 double slots via bit-cast with a
  CAS retry loop.

## [1.0.0] - 2026-05-03

First stable release. Hardens the runtime under contention and at high
cardinality, brings the OTLP path up to spec, fixes deadlock and leak
risks in the export pipeline, and lands a full audit of the documentation
against the actual public API.

### Added
- `OTEL_METRIC_CARDINALITY_LIMIT` (default 2000) caps distinct label sets
  per vector metric. Excess label sets aggregate into one shared series
  tagged `otel.metric.overflow=true`. Dropped count exposed via
  `instrument_registry:cardinality_dropped/1`.
- `instrument_otlp_retry` module: bounded exponential backoff with
  `Retry-After` honoured, classifying transport and HTTP errors per the
  OTel spec. Configurable via `OTEL_EXPORTER_OTLP_MAX_RETRIES`,
  `OTEL_EXPORTER_OTLP_RETRY_INITIAL_DELAY_MS`,
  `OTEL_EXPORTER_OTLP_RETRY_MAX_DELAY_MS`.
- Span attribute value length limit
  (`OTEL_ATTRIBUTE_VALUE_LENGTH_LIMIT`), per-event and per-link attribute
  count limits (`OTEL_EVENT_ATTRIBUTE_COUNT_LIMIT`,
  `OTEL_LINK_ATTRIBUTE_COUNT_LIMIT`); excess attributes counted in
  `dropped_attributes_count` and emitted as `droppedAttributesCount` in
  OTLP.
- Tracestate caps at 32 entries / 256 bytes; baggage caps at 180
  entries / 8192 bytes per W3C trace-context.
- `instrument_attributes:apply_limits/2,3` and `truncate_value/2`
  helpers.
- Span Export Path section in the design and internals guide explaining
  the full chain from `end_span` to OTLP, with explicit notes that
  `instrument_tracer_nif` serves the flight recorder only.
- Test coverage for 28 documented public APIs that previously had no
  call sites in CT (`instrument_propagation:inject_headers/extract_headers/call_with_context/cast_with_context`,
  `instrument_context:remove_value/spawn_link_with_context`,
  `instrument_config:set_verbose_tracing/is_verbose_tracing/enable_exporter/disable_exporter`,
  `instrument_tracer:record_exception/update_name`,
  `instrument_test:assert_log_trace_context`,
  `instrument_logger:add_trace_context/emit`,
  `instrument_metric:remove_label/clear_labels/set_gauge_to_current_time`,
  exporter callback contracts).

### Changed
- Batch processor `force_flush/0` and the max-batch-size trigger no
  longer block the gen_server loop. An export worker is spawned and
  completion arrives as `{export_done, ...}`; concurrent flush callers
  are batched and replied to via `gen_server:reply/2`. A kill timer
  enforces `export_timeout_millis` without blocking the loop.
- `instrument_exporter` shutdown now casts the hook unregister so the
  reply path stays unblocked.
- `instrument_span_processor:on_start/2` now has a 5 s safety timeout;
  the tracer hot path uses the inline `persistent_term` form.
- OTLP exporters return `{error, retryable, _}` vs `{error, permanent, _}`.
  The batch processor keeps retryable batches for up to
  `max_batch_retries` cycles and drops permanent errors.
- Probability sampler hashes the upper 8 bytes of the trace id, matching
  the Java/Go/Python reference SDKs.
- Status transitions now follow the OTel spec: `unset -> ok|error`,
  `error -> ok` (success overrides), `error -> error` updates the
  description, `ok` is final.
- Batch processor clamps `max_export_batch_size` to `max_queue_size` on
  init with a warning.
- Documentation snippets fixed across `guides/`, `book/`, and `README.md`:
  6 syntax bugs, 8+ calls to non-existent or wrong-arity functions,
  wrong arg shapes for `set_sampler`, `parent_based` config,
  `metric_view` record literal, `exporter_otlp:export`, and stale config
  keys (`schedule_delay_millis`, `export_timeout_millis`).
- Book chapter prose smoothed for readability.

### Fixed
- Histogram exemplar reservoirs are now freed on unregister.
- Registry unregister no longer scans the global `persistent_term`
  index; iterates the metric's own `labels_map` instead.
- Baggage `set/remove/clear` use `set_current/1` so process-dictionary
  context tokens no longer accumulate.
- `instrument_exporter_console:export/2` and
  `instrument_metrics_exporter_console:exporter_export/2` no longer
  crash when configured with `output => {file, Path}`. The `{file, Fd}`
  wrapper used by `shutdown/1` is now unwrapped before
  `io:put_chars/2`.

### Removed
- `instrument_exporter_kafka` documentation section: the module never
  existed in `src/exporters/`.

### Deprecated
- _None._

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
