%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% OpenTelemetry-compatible records for the instrument library.

-ifndef(INSTRUMENT_OTEL_HRL).
-define(INSTRUMENT_OTEL_HRL, true).

%% W3C TraceContext compliant span context
-record(span_ctx, {
  trace_id :: <<_:128>> | undefined,           % 16 bytes (128 bits)
  span_id :: <<_:64>> | undefined,             % 8 bytes (64 bits)
  trace_flags = 1 :: 0 | 1,                    % sampled flag
  trace_state = [] :: [{binary(), binary()}],  % vendor-specific key-value pairs
  is_remote = false :: boolean()               % whether this context was extracted from remote
}).

%% Span event (timestamped annotation)
%% Must be defined before span record
-record(span_event, {
  name :: binary(),
  timestamp :: integer(),                      % wall clock time in nanoseconds (Unix epoch)
  attributes = #{} :: map()
}).

%% Span link (reference to another span)
%% Must be defined before span record
-record(span_link, {
  ctx :: #span_ctx{},
  attributes = #{} :: map()
}).

%% Span record for tracing
-record(span, {
  name :: binary(),
  ctx :: #span_ctx{},
  parent_ctx :: #span_ctx{} | undefined,
  kind = internal :: client | server | producer | consumer | internal,
  start_time :: integer(),                     % wall clock time in nanoseconds (Unix epoch)
  end_time :: integer() | undefined,
  attributes = #{} :: map(),
  events = [] :: [#span_event{}],
  links = [] :: [#span_link{}],
  status = unset :: unset | ok | {error, binary()},
  is_recording = true :: boolean()
}).

%% Resource (describes the entity producing telemetry)
-record(resource, {
  attributes = #{} :: map(),
  schema_url :: binary() | undefined
}).

%% Scope (describes the instrumentation scope)
-record(scope, {
  name :: binary(),
  version :: binary() | undefined,
  attributes = #{} :: map(),
  schema_url :: binary() | undefined
}).

%% Tracer record
-record(tracer, {
  name :: binary(),
  version :: binary() | undefined,
  schema_url :: binary() | undefined,
  resource :: #resource{} | undefined
}).

%% Meter record for metrics
-record(meter, {
  name :: binary(),
  version :: binary() | undefined,
  schema_url :: binary() | undefined,
  resource :: #resource{} | undefined
}).

%% OTel instrument descriptor
-record(otel_instrument, {
  name :: binary(),
  kind :: counter | up_down_counter | histogram | gauge | observable_counter | observable_gauge | observable_up_down_counter,
  description :: binary() | undefined,
  unit :: binary() | undefined,
  meter :: #meter{} | undefined,
  %% Internal handle to the underlying metric
  handle :: term()
}).

%% Metric view for transformation and filtering
-record(metric_view, {
  name :: binary() | undefined,              % New name for the metric (optional)
  description :: binary() | undefined,       % New description (optional)
  instrument_name :: binary() | '_',         % Pattern to match instrument names
  instrument_type :: atom() | '_',           % counter | gauge | histogram | '_'
  meter_name :: binary() | '_',              % Pattern to match meter names
  attribute_keys :: [binary()] | undefined,  % Attributes to keep (undefined = all)
  aggregation :: atom() | undefined,         % Aggregation type override
  boundaries :: [number()] | undefined       % Histogram boundaries override
}).

%% Sampling result from a sampler
-record(sampling_result, {
  decision :: drop | record_only | record_and_sample,
  attributes = #{} :: map(),
  trace_state = [] :: [{binary(), binary()}]
}).

%% Log record for logger integration
-record(log_record, {
  timestamp :: integer() | undefined,          % wall clock time in nanoseconds
  observed_timestamp :: integer() | undefined, % when the log was observed
  severity_number :: integer() | undefined,    % 1-24 severity level
  severity_text :: binary() | undefined,       % e.g., "INFO", "ERROR"
  body :: term(),                              % log message
  attributes = #{} :: map(),
  trace_id :: <<_:128>> | undefined,
  span_id :: <<_:64>> | undefined,
  trace_flags :: 0 | 1 | undefined,
  resource :: #resource{} | undefined,
  scope :: #scope{} | undefined
}).

%% Severity numbers per OTel spec
-define(SEVERITY_TRACE, 1).
-define(SEVERITY_TRACE2, 2).
-define(SEVERITY_TRACE3, 3).
-define(SEVERITY_TRACE4, 4).
-define(SEVERITY_DEBUG, 5).
-define(SEVERITY_DEBUG2, 6).
-define(SEVERITY_DEBUG3, 7).
-define(SEVERITY_DEBUG4, 8).
-define(SEVERITY_INFO, 9).
-define(SEVERITY_INFO2, 10).
-define(SEVERITY_INFO3, 11).
-define(SEVERITY_INFO4, 12).
-define(SEVERITY_WARN, 13).
-define(SEVERITY_WARN2, 14).
-define(SEVERITY_WARN3, 15).
-define(SEVERITY_WARN4, 16).
-define(SEVERITY_ERROR, 17).
-define(SEVERITY_ERROR2, 18).
-define(SEVERITY_ERROR3, 19).
-define(SEVERITY_ERROR4, 20).
-define(SEVERITY_FATAL, 21).
-define(SEVERITY_FATAL2, 22).
-define(SEVERITY_FATAL3, 23).
-define(SEVERITY_FATAL4, 24).

-endif.
