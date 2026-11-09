# Design and Internals

This guide describes the architecture, design decisions, and internal workings of the instrument library for developers who want to understand or extend the system.

## Architecture Overview

```
+------------------+     +------------------+     +------------------+
|   Application    |     |    Tracing       |     |    Metrics       |
|------------------|     |------------------|     |------------------|
| instrument_app   |---->| instrument_tracer|     | instrument_counter|
| instrument_sup   |     | instrument_sampler     | instrument_gauge  |
| instrument_config|     | instrument_span_*|     | instrument_hist...|
+------------------+     +------------------+     +------------------+
         |                       |                       |
         v                       v                       v
+------------------+     +------------------+     +------------------+
|    Context       |     |   Processing     |     |    Registry      |
|------------------|     |------------------|     |------------------|
| instrument_ctx   |<--->| span_processor   |     | instrument_reg...|
| instrument_prop..      | instrument_exp...|<--->| instrument_lib   |
+------------------+     +------------------+     +------------------+
                                |
                                v
                         +------------------+
                         | Flight Recorder  |
                         |------------------|
                         | flight_recorder  |
                         | tracer_pool      |
                         | tracer_nif (C)   |
                         +------------------+
```

### Startup Sequence

1. **instrument_app:start/2** - Initializes configuration via `instrument_config:init()`
2. Creates the `instrument_span_exporters` ETS table for span export hooks
3. **instrument_sup:start_link/0** - Starts the supervisor tree

The supervisor (`instrument_sup`) starts these children with the `rest_for_one` strategy: a crashed child is restarted together with the children started after it. Ten restarts within a minute stop the application.

| Order | Child ID | Module | Purpose |
|-------|----------|--------|---------|
| 1 | table_owner | instrument_table_owner | Owns the shared ETS tables; clears leftover state at application start |
| 2 | registry | instrument_registry | Destructive metric operations (unregister, clear) |
| 3 | exporter | instrument_exporter | Span export batching |
| 4 | metrics_exporter | instrument_metrics_exporter | Metrics export |
| 5 | log_exporter | instrument_log_exporter | Log export |
| 6 | span_processor | instrument_span_processor | Span processing chain |
| 7 | tracer_pool | instrument_tracer_pool | Flight recorder worker supervisor |
| 8 | flight_recorder | instrument_flight_recorder | Message tracing |

The batch span processor and the exporter servers of the simple and tail-sampling processors are added as further children when they are registered.

### Crash Recovery

- The table owner does nothing but hold tables, so a crash of the registry or an exporter keeps every metric series and registration.
- Registered exporters and processors are recorded in the `instrument_registrations` table. A restarted exporter manager or span processor manager initializes them again, so export keeps working.
- Stopping and starting the application still starts from a clean slate.

### Design Principles

**Lock-free Operations**: Counters and gauges use NIF-based C11 atomics for updates. Histograms use the OTP `atomics` module, with bucket counts stored as int64 slots and the running sum kept as IEEE-754 bits in a CAS-retry loop. Both paths avoid locks entirely.

**Series Store**: Every metric series (one label set of one metric) is its own entry. Creating one is a single `ets:insert_new` plus `persistent_term` puts under fresh keys, so it never goes through a process and never triggers a VM-wide garbage collection. See [Series Store](#series-store).

**Bounded Queues**: Every process that receives telemetry by message (span and log exporters, batch processor, flight recorder workers) has its intake checked by the sender, which drops instead of queuing past a limit.

**Process Dictionary Context**: Span context is stored in the process dictionary for zero-cost reads within a process.

## Module Organization

### By Subsystem

| Subsystem | Modules | Purpose |
|-----------|---------|---------|
| Application | `instrument_app`, `instrument_sup`, `instrument_config` | Lifecycle and configuration |
| Tracing | `instrument_tracer`, `instrument_sampler`, `instrument_id` | Span creation and sampling |
| Metrics | `instrument_counter`, `instrument_gauge`, `instrument_histogram` | Metric types |
| Context | `instrument_context`, `instrument_propagator`, `instrument_propagator_*` | Context propagation |
| Processing | `instrument_span_processor`, `instrument_span_processor_*`, `instrument_exporter` | Span processing pipeline |
| Flight Recorder | `instrument_flight_recorder`, `instrument_tracer_pool`, `instrument_tracer_nif` | Message/process tracing via `erl_tracer` NIF (not used by the span hot path) |
| Registry | `instrument_registry`, `instrument_series`, `instrument_lib` | Metric storage |
| Export plumbing | `instrument_admission`, `instrument_export_batcher`, `instrument_export_server` | Bounded intake, batching, serialized exports |

### Module Dependencies

```
instrument_tracer
    |
    +---> instrument_context (span storage)
    +---> instrument_sampler (sampling decisions)
    +---> instrument_id (ID generation)
    +---> instrument_span_processor (on_start/on_end hooks)
    +---> instrument_flight_recorder (message tracing)
```

### Key Modules

**instrument_tracer**: Core span lifecycle management. Handles span creation, context attachment, and export hooks. Uses the process dictionary via `instrument_context` to maintain the current span stack.

**instrument_series**: The metric store. Families (one per metric name) and series (one per label set) are created without any process hop; writes and scrapes read `persistent_term` only.

**instrument_registry**: Owns the store's tables and runs the rare destructive operations (unregister, remove a label set, clear). It is on no create, write or scrape path.

**instrument_span_processor**: Manages a chain of span processors, invoking `on_start/2` and `on_end/1` callbacks. Supports both simple (immediate) and batch processing.

**instrument_exporter**: Batches completed spans and distributes them to registered exporters. Default batch size is 512 spans with a 5-second timeout, and at most 2048 spans wait; extra spans are dropped and counted. The tracer only calls it while an exporter is registered. Configured trace exporters (`OTEL_TRACES_EXPORTER`) go through the batch span processor instead.

**instrument_flight_recorder**: Low-overhead message tracing using `erlang:trace` with a custom erl_tracer NIF. Distributes trace events across a worker pool to avoid single-process bottlenecks. The NIF (`instrument_tracer_nif`) implements BEAM `erl_tracer` callbacks (`enabled/3`, `trace/5`, plus the specialised variants) and is invoked by the VM, not by user code. It is not in the `start_span`/`end_span` path and cannot be reused to accelerate span operations; see [Span Export Path](#span-export-path) for how spans actually reach exporters.

## Key Data Structures

### Tracing Records (instrument_otel.hrl)

**#span_ctx{}** - W3C TraceContext identifier

```erlang
-record(span_ctx, {
  trace_id :: <<_:128>>,           % 16 bytes (128 bits)
  span_id :: <<_:64>>,             % 8 bytes (64 bits)
  trace_flags = 1 :: 0 | 1,        % sampled flag
  trace_state = [] :: [{binary(), binary()}],  % vendor key-value pairs
  is_remote = false :: boolean()   % extracted from remote?
}).
```

**#span{}** - Complete span record

```erlang
-record(span, {
  name :: binary(),
  ctx :: #span_ctx{},
  parent_ctx :: #span_ctx{} | undefined,
  kind = internal :: client | server | producer | consumer | internal,
  start_time :: integer(),         % monotonic nanoseconds
  end_time :: integer() | undefined,
  attributes = #{} :: map(),
  events = [] :: [#span_event{}],
  links = [] :: [#span_link{}],
  status = unset :: unset | ok | {error, binary()},
  is_recording = true :: boolean()
}).
```

**#span_event{}** - Timestamped annotation

```erlang
-record(span_event, {
  name :: binary(),
  timestamp :: integer(),          % monotonic nanoseconds
  attributes = #{} :: map()
}).
```

**#sampling_result{}** - Sampler output

```erlang
-record(sampling_result, {
  decision :: drop | record_only | record_and_sample,
  attributes = #{} :: map(),
  trace_state = [] :: [{binary(), binary()}]
}).
```

### Metrics Records (instrument.hrl)

**#metric{}** - Core metric wrapper

```erlang
-record(metric, {
  name,
  handle :: term(),                % NIF resource or atomics array
  collect :: tuple() | undefined,  % {Module, Function, Args}
  description :: binary() | undefined,
  unit :: binary() | undefined,
  meter :: binary() | undefined,
  attributes = #{} :: map()
}).
```

Each series is a `#metric{}` holding one cell. Simple-API records embed the cell, so their writes go straight to the NIF.

**#family{}** - One metric name in the series store

```erlang
-record(family, {
  kind,                            % counter | gauge | histogram | observable_*
  help = <<>>,
  declared_labels,                 % vec API: label names; meter: undefined
  boundaries,                      % histograms only
  start_time,                      % creation time, ns
  idx,                             % slot in the family chain
  row_seq                          % atomics counter numbering its series
}).
```

## Internal Workflows

### Span Lifecycle

```
start_span(Name, Opts)
    |
    v
[Check tracing enabled] --no--> [Create noop span] --> [Attach] --> Return
    |
    yes
    v
[Get parent context from opts or current span]
    |
    v
[Generate trace_id (new trace) or inherit from parent]
[Generate span_id]
    |
    v
[Call sampler: should_sample/6]
    |
    +---> decision = drop         --> is_recording = false, trace_flags = 0
    +---> decision = record_only  --> is_recording = true, trace_flags = 0
    +---> decision = record_and_sample --> is_recording = true, trace_flags = 1
    |
    v
[Create #span{} with merged attributes]
    |
    v
[If is_recording: call span_processor:on_start/2]
    |
    v
[Attach span to context (process dictionary)]
    |
    v
[If flight recorder enabled: enable_flight_tracing/1]
    |
    v
Return #span{}
```

### Span End Flow

```
end_span(Span)
    |
    v
[If is_recording = false] --> [Detach from context] --> Return ok
    |
    v
[Set end_time = now()]
    |
    v
[Call span_processor:on_end/1]
    |
    v
[Mark is_recording = false]
    |
    v
[Call all registered exporters via ETS lookup]
    |
    v
[If flight recorder owner: disable tracing]
    |
    v
[Detach span from context, restore parent if any]
    |
    v
Return ok
```

### Span Export Path

The Span End Flow above shows two exit doors. Following each one to OTLP:

**1. Span processor chain (batched, async).** `instrument_tracer:end_span/1` (`src/instrument_tracer.erl:370`) calls `instrument_span_processor:on_end_inline/1`, which reads the cached processor list from `persistent_term` and invokes `Module:on_end(Span)` on each. With the batch processor registered, that cast queues the span; a worker spawned from the batch processor's gen_server later calls `Exporter:export(OrderedSpans, State)` (`src/processors/instrument_span_processor_batch.erl:476`). For OTLP that becomes a JSON-encoded HTTP POST to the configured endpoint, with retry handling in `instrument_otlp_retry`.

**2. Direct exporter hooks (synchronous, sampled spans only).** `instrument_tracer:end_span/1` also runs the per-span exporter funs registered via `instrument_tracer:register_exporter/1` (read from `persistent_term`), inline on the span-ending process. This path only fires when `trace_flags = 1` (sampled).

Call chain for the batched OTLP path:

```
instrument_tracer:end_span/1                     (src/instrument_tracer.erl:370)
    -> instrument_span_processor:on_end_inline/1
    -> instrument_span_processor_batch:on_end/1
    -> gen_server cast, batched
    -> instrument_exporter_otlp:export/2         (src/exporters/instrument_exporter_otlp.erl:104)
    -> instrument_otlp_retry over HTTP POST

(`instrument_tracer:export_span/1` mentioned in path 2 is an internal helper,
not an exported public API.)
```

**Default state: nothing leaves the VM.** No processor or exporter is registered out of the box. Spans complete, `on_end_inline` finds an empty processor list, and the data is discarded. Setting `OTEL_TRACES_EXPORTER` (or the `span_exporter` application setting) registers the batch processor with that exporter at startup. Non-recording spans (sampler decision = `drop`) short-circuit before the export path entirely; only spans with `trace_flags = 1` reach the direct `register_exporter/1` hooks, which exist only while `instrument_exporter` has an exporter registered.

**Backpressure.** `instrument_span_processor_batch:on_end/1` and `instrument_exporter:export_span/1` reserve a slot in an `atomics` counter before casting (`instrument_admission`). Past the queue limit the span is dropped in the ending process, so a slow collector cannot grow the receiver's mailbox.

### Metrics Recording Flow

```
instrument_meter:add(Counter, 1, #{method => <<"GET">>})
    |
    v
[Sort attributes into the series key]
    |
    v
[persistent_term:get({instrument_label, Name, Key})]
    |
    +---> found: #metric{} row --> [NIF atomic increment]
    |
    +---> first write of this label set:
              |
              v
          [Check the per-metric cardinality limit]
              |
              v
          [ets:insert_new the row: exactly one writer wins]
              |
              v
          [Winner publishes two fresh persistent_term keys]
              |
              v
          [NIF atomic increment]
```

Record-held simple-API metrics skip the lookup: the record holds the cell.

### Context Propagation Flow

```
Outbound (inject):
    instrument_propagator:inject(Carrier)
        |
        v
    [Get current context from process dictionary]
        |
        v
    [For each registered propagator:]
        +---> propagator:inject(Ctx, Carrier) --> Updated Carrier
        |
        v
    Return final Carrier with all headers


Inbound (extract):
    instrument_propagator:extract(Carrier)
        |
        v
    [Create new empty context]
        |
        v
    [For each registered propagator:]
        +---> propagator:extract(Carrier, Ctx) --> Updated Ctx
        |
        v
    Return context with span_ctx, baggage, etc.
```

### Flight Recorder Message Flow

```
[Root span starts]
    |
    v
[enable_flight_tracing(TraceId)]
    |
    v
[Store label in process dictionary]
    |
    v
[Get tracer state from instrument_tracer_pool]
    |
    v
[erlang:trace(self(), true, [send, 'receive', set_on_spawn,
                             {tracer, instrument_tracer_nif, State}])]
    |
    v
[All send/receive events captured by NIF]
    |
    +---> [NIF hashes tracee PID to select worker]
    |         |
    |         v
    |     [Worker has max_queue events waiting? drop and count]
    |         |
    |         v
    |     [Payload over max_payload_bytes? replace by {truncated, Size}]
    |         |
    |         v
    |     [Send {trace, ...} to the worker, resolved by registered name]
    |         |
    |         v
    |     [Worker inserts into ETS ring buffer, acks the NIF counter,
    |      asks the recorder to evict if the buffer is over its limit]
    |
    v
[On the owning span's end: erlang:trace(self(), false, ...)]
```

## Extension Points

### Custom Sampler

Implement the `instrument_sampler` behavior:

```erlang
-module(my_sampler).
-behaviour(instrument_sampler).

-export([should_sample/7, get_description/1]).

-include_lib("instrument/include/instrument_otel.hrl").

%% Rate limit to N spans per second
should_sample(Config, TraceId, SpanName, SpanKind, Attributes, Links, ParentCtx) ->
  RateLimit = maps:get(rate_limit, Config, 100),
  case check_rate_limit(RateLimit) of
    allow ->
      #sampling_result{
        decision = record_and_sample,
        attributes = #{},
        trace_state = []
      };
    deny ->
      #sampling_result{decision = drop}
  end.

get_description(Config) ->
  RateLimit = maps:get(rate_limit, Config, 100),
  iolist_to_binary(io_lib:format("RateLimitSampler{~p/s}", [RateLimit])).

%% Register:
%% instrument_sampler:set_sampler(my_sampler, #{rate_limit => 50}).
```

### Custom Span Processor

Implement the `instrument_span_processor` behavior:

```erlang
-module(my_span_processor).
-behaviour(instrument_span_processor).

-export([init/1, on_start/2, on_end/1, shutdown/1, force_flush/1]).

-include_lib("instrument/include/instrument_otel.hrl").

init(Config) ->
  %% Initialize state (e.g., open connections)
  {ok, #{filter => maps:get(filter, Config, fun(_) -> true end)}}.

on_start(Span, _ParentCtx) ->
  %% Called synchronously at span start
  %% Add attributes, modify span, etc.
  Span#span{attributes = maps:put(<<"processor">>, <<"custom">>,
                                  Span#span.attributes)}.

on_end(Span) ->
  %% Called asynchronously at span end
  %% Filter, transform, forward to external systems
  case should_export(Span) of
    true -> send_to_analytics(Span);
    false -> ok
  end.

shutdown(_State) ->
  ok.

force_flush(_State) ->
  ok.

%% Register:
%% instrument_span_processor:register(my_span_processor, #{}).
```

### Custom Exporter

Implement the exporter callbacks:

```erlang
-module(my_exporter).

-export([init/1, export/2, shutdown/1, force_flush/1]).

-include_lib("instrument/include/instrument_otel.hrl").

init(Config) ->
  Endpoint = maps:get(endpoint, Config),
  {ok, #{endpoint => Endpoint, conn => connect(Endpoint)}}.

export(Spans, State) ->
  %% Spans is a list of #span{} records
  #{endpoint := Endpoint, conn := Conn} = State,
  Payload = encode_spans(Spans),
  case send_request(Conn, Endpoint, Payload) of
    ok ->
      {ok, State};
    {error, Reason} ->
      logger:warning("Export failed: ~p", [Reason]),
      {error, Reason, State}
  end.

shutdown(#{conn := Conn}) ->
  close(Conn),
  ok.

force_flush(State) ->
  {ok, State}.

%% Optional: run exports outside the exporter server. Only for exporters
%% whose state is usable from another process (no raw files).
%% export_async() -> true.

%% Register:
%% instrument_exporter:register(#{module => my_exporter,
%%                                config => #{endpoint => "..."}}).
```

### Custom Propagator

Implement the `instrument_propagator` behavior:

```erlang
-module(my_propagator).
-behaviour(instrument_propagator).

-export([inject/2, extract/2, fields/0]).

-define(HEADER, <<"x-my-trace">>).

inject(Ctx, Carrier) ->
  case maps:get(span_ctx, Ctx, undefined) of
    undefined ->
      Carrier;
    #span_ctx{trace_id = TraceId, span_id = SpanId} ->
      Value = encode(TraceId, SpanId),
      maps:put(?HEADER, Value, Carrier)
  end.

extract(Carrier, Ctx) ->
  case maps:get(?HEADER, Carrier, undefined) of
    undefined ->
      Ctx;
    Value ->
      {TraceId, SpanId} = decode(Value),
      SpanCtx = #span_ctx{
        trace_id = TraceId,
        span_id = SpanId,
        is_remote = true
      },
      maps:put(span_ctx, SpanCtx, Ctx)
  end.

fields() ->
  [?HEADER].

%% Register:
%% instrument_propagator:register(my_propagator).
```

## Performance Design Choices

### Lock-free Metric Storage

Counters and gauges use C11 `_Atomic double` via a small NIF. Inc/dec
run a CAS loop in C, set/get are single atomic load/stores:

```c
// From c_src/gauge.c
static void instrument_gauge_change(instrument_gauge_t *g, double delta) {
    double current = atomic_load(&g->value);
    while (!atomic_compare_exchange_weak(&g->value, &current, current + delta))
        ;
}
```

Histograms use the OTP `atomics` module instead. Each histogram owns
one atomics array of size N+2:

- slot 1 — IEEE-754 bit pattern of the running sum, updated via
  `atomics:compare_exchange/4` in a small Erlang CAS loop
  (see `instrument_atomics:inc_at/3`).
- slots 2..N+2 — bucket counts as signed int64, updated via
  `atomics:add/3`.

Both paths give:
- Lock-free updates using CAS
- No contention between concurrent writers
- Sub-microsecond update latency on the hot path

### Series Store

`instrument_series` keeps every series as its own entry:

| Where | Key | Value |
|-------|-----|-------|
| ETS `instrument_series` | `{Name, family}`, `{Name, SeriesKey}` | family meta, series row (the creation arbiter) |
| `persistent_term` | `{instrument_family, Name}` | `#family{}` |
| `persistent_term` | `{instrument_label, Name, CacheKey}` | series row, the write hot path |
| `persistent_term` | `{instrument_row, Name, N}` | series N of a family, walked by scrapes |
| `persistent_term` | `{instrument_family_idx, K}` | family K, walked by scrapes |

Rules that keep it cheap:
- Creation is decided by `ets:insert_new`: one writer wins, the others reuse its row.
- Only the winner writes that series' `persistent_term` keys, and only fresh ones. Replacing a `persistent_term` value makes every process scan its heap; adding a new key does not.
- Scrapes count up the family and series counters and read `persistent_term`; they touch no ETS table.
- Erasing keys (unregister, clear) does trigger the VM-wide scan. That only happens on administrative operations.

Labeled series export under the metric's own name. A family mixing attribute key sets renders the union of label names, with absent labels empty.

### Process Dictionary Context

Context is stored in the process dictionary:

```erlang
% From instrument_context.erl
current() ->
  case erlang:get(?CONTEXT_KEY) of
    undefined -> new();
    Ctx -> Ctx
  end.

set_current(Ctx) when is_map(Ctx) ->
  erlang:put(?CONTEXT_KEY, Ctx),
  ok.
```

Benefits:
- Zero-cost reads (direct memory access)
- No message passing or function calls
- Natural process isolation

### Worker Pool Distribution

The flight recorder distributes trace events across workers:

```c
// From c_src/instrument_tracer_nif.c
ErlNifUInt64 hash = enif_hash(ERL_NIF_INTERNAL_HASH, tracee, 0);
unsigned int worker_idx = hash % pool_size;
```

This avoids the single-process bottleneck that would occur if all trace events went to one handler. Each worker has a counter in a NIF resource: the NIF increments it before sending and drops the event once `flight_recorder_max_queue` events are outstanding, and the worker decrements it after each batch. This bounds mailbox memory to about pool size times `max_queue` times `max_payload_bytes`.

### Batched Export

Spans are batched before export:

| Setting | Default | Purpose |
|---------|---------|---------|
| max_export_batch_size | 512 | Spans per batch |
| schedule_delay_millis | 5000 | Time trigger |
| max_queue_size | 2048 | Queue limit, enforced before the cast |
| export_timeout_millis | 30000 | Export timeout |

Each export sends at most `max_export_batch_size` spans. `force_flush/0` waits until the queue is exported or one export timeout passes.

### Performance Summary

| Operation | Mechanism | Typical Latency | Concurrency |
|-----------|-----------|-----------------|-------------|
| Metric increment | NIF atomic CAS | <100ns | Lock-free |
| Labeled metric write | persistent_term + NIF | ~200ns | Lock-free |
| New label set | ets:insert_new + fresh persistent_term keys | grows with the number of persistent_term keys in the VM | No process hop, no global GC |
| Context read | Process dictionary | <10ns | Process-local |
| Span start | Erlang + sampling | ~1-5us | Per-process |
| Span end | Async cast | <1us | Non-blocking |
| Flight trace event | NIF + hash | ~500ns | Pool-distributed |
| Batch export | Async process | Background | Configurable |
