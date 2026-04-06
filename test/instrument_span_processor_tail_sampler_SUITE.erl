%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_span_processor_tail_sampler_SUITE).
-author("benoitc").

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("instrument_otel.hrl").

-export([
  all/0,
  init_per_suite/1,
  end_per_suite/1,
  init_per_testcase/2,
  end_per_testcase/2
]).

-export([
  error_spans_always_kept_test/1,
  ok_status_match_test/1,
  slow_spans_kept_test/1,
  fast_spans_filtered_test/1,
  attribute_match_kept_test/1,
  attribute_exists_match_test/1,
  health_check_dropped_test/1,
  probability_sampling_test/1,
  rule_priority_test/1,
  exception_event_detected_test/1,
  has_event_match_test/1,
  duration_comparison_operators_test/1,
  non_recording_spans_ignored_test/1,
  no_exporter_configured_test/1,
  invalid_rule_rejected_test/1,
  integration_with_tracer_test/1,
  undefined_end_time_test/1
]).

all() ->
  [
    error_spans_always_kept_test,
    ok_status_match_test,
    slow_spans_kept_test,
    fast_spans_filtered_test,
    attribute_match_kept_test,
    attribute_exists_match_test,
    health_check_dropped_test,
    probability_sampling_test,
    rule_priority_test,
    exception_event_detected_test,
    has_event_match_test,
    duration_comparison_operators_test,
    non_recording_spans_ignored_test,
    no_exporter_configured_test,
    invalid_rule_rejected_test,
    integration_with_tracer_test,
    undefined_end_time_test
  ].

init_per_suite(Config) ->
  _ = application:ensure_all_started(crypto),
  ok = application:start(instrument),
  Config.

end_per_suite(_Config) ->
  ok = application:stop(instrument),
  ok.

init_per_testcase(_TestCase, Config) ->
  %% Clear all processors
  lists:foreach(fun(M) ->
    instrument_span_processor:unregister(M)
  end, instrument_span_processor:list()),
  %% Clear persistent term state
  catch persistent_term:erase({instrument_span_processor_tail_sampler, state}),
  Config.

end_per_testcase(_TestCase, _Config) ->
  %% Clear all processors
  lists:foreach(fun(M) ->
    instrument_span_processor:unregister(M)
  end, instrument_span_processor:list()),
  catch persistent_term:erase({instrument_span_processor_tail_sampler, state}),
  ok.

%% ============================================================================
%% Test Cases
%% ============================================================================

error_spans_always_kept_test(_Config) ->
  %% Setup collecting exporter
  Self = self(),
  setup_mock_exporter(Self),

  ok = instrument_span_processor:register(instrument_span_processor_tail_sampler, #{
    always_keep => [{status, error}],
    default_ratio => 0.0,  %% Drop all non-error spans
    exporter => mock_tail_exporter,
    exporter_config => #{}
  }),

  %% Create and end error span
  ErrorSpan = make_span(<<"error_span">>, #{status => {error, <<"test error">>}}),
  instrument_span_processor_tail_sampler:on_end(ErrorSpan),

  %% Should be exported
  receive
    {exported, [Span]} ->
      ?assertEqual(<<"error_span">>, Span#span.name)
  after 1000 ->
    ct:fail(error_span_not_exported)
  end,

  %% Create and end ok span
  OkSpan = make_span(<<"ok_span">>, #{status => ok}),
  instrument_span_processor_tail_sampler:on_end(OkSpan),

  %% Should NOT be exported
  receive
    {exported, _} -> ct:fail(ok_span_should_be_dropped)
  after 100 ->
    ok
  end,

  cleanup_mock_exporter(),
  ok.

ok_status_match_test(_Config) ->
  %% Test that {status, ok} rule works correctly
  State = make_state(#{always_keep => [{status, ok}], default_ratio => 0.0}),

  OkSpan = make_span(<<"ok_span">>, #{status => ok}),
  ErrorSpan = make_span(<<"error_span">>, #{status => {error, <<"err">>}}),
  UnsetSpan = make_span(<<"unset_span">>, #{status => unset}),

  ?assert(instrument_span_processor_tail_sampler:should_keep(OkSpan, State)),
  ?assertNot(instrument_span_processor_tail_sampler:should_keep(ErrorSpan, State)),
  ?assertNot(instrument_span_processor_tail_sampler:should_keep(UnsetSpan, State)),
  ok.

slow_spans_kept_test(_Config) ->
  State = make_state(#{
    always_keep => [{duration_ms, '>', 100}],
    default_ratio => 0.0
  }),

  %% 150ms span should be kept
  SlowSpan = make_span(<<"slow_span">>, #{duration_ns => 150 * 1000000}),
  ?assert(instrument_span_processor_tail_sampler:should_keep(SlowSpan, State)),

  %% 50ms span should be dropped
  FastSpan = make_span(<<"fast_span">>, #{duration_ns => 50 * 1000000}),
  ?assertNot(instrument_span_processor_tail_sampler:should_keep(FastSpan, State)),

  %% Exactly 100ms should NOT match '>'
  ExactSpan = make_span(<<"exact_span">>, #{duration_ns => 100 * 1000000}),
  ?assertNot(instrument_span_processor_tail_sampler:should_keep(ExactSpan, State)),

  ok.

fast_spans_filtered_test(_Config) ->
  State = make_state(#{
    always_keep => [{duration_ms, '<', 10}],
    default_ratio => 0.0
  }),

  %% 5ms span should be kept (fast)
  FastSpan = make_span(<<"fast_span">>, #{duration_ns => 5 * 1000000}),
  ?assert(instrument_span_processor_tail_sampler:should_keep(FastSpan, State)),

  %% 50ms span should be dropped
  SlowSpan = make_span(<<"slow_span">>, #{duration_ns => 50 * 1000000}),
  ?assertNot(instrument_span_processor_tail_sampler:should_keep(SlowSpan, State)),

  ok.

attribute_match_kept_test(_Config) ->
  State = make_state(#{
    always_keep => [{attribute, <<"priority">>, high}],
    default_ratio => 0.0
  }),

  %% Span with matching attribute
  HighPrioritySpan = make_span(<<"high_prio">>, #{
    attributes => #{<<"priority">> => high}
  }),
  ?assert(instrument_span_processor_tail_sampler:should_keep(HighPrioritySpan, State)),

  %% Span with different value
  LowPrioritySpan = make_span(<<"low_prio">>, #{
    attributes => #{<<"priority">> => low}
  }),
  ?assertNot(instrument_span_processor_tail_sampler:should_keep(LowPrioritySpan, State)),

  %% Span without attribute
  NoPrioritySpan = make_span(<<"no_prio">>, #{}),
  ?assertNot(instrument_span_processor_tail_sampler:should_keep(NoPrioritySpan, State)),

  ok.

attribute_exists_match_test(_Config) ->
  State = make_state(#{
    always_keep => [{attribute_exists, <<"debug">>}],
    default_ratio => 0.0
  }),

  %% Span with attribute (any value)
  WithAttr = make_span(<<"with_debug">>, #{
    attributes => #{<<"debug">> => true}
  }),
  ?assert(instrument_span_processor_tail_sampler:should_keep(WithAttr, State)),

  %% Span with attribute set to false
  WithFalse = make_span(<<"with_false">>, #{
    attributes => #{<<"debug">> => false}
  }),
  ?assert(instrument_span_processor_tail_sampler:should_keep(WithFalse, State)),

  %% Span without attribute
  WithoutAttr = make_span(<<"without_debug">>, #{}),
  ?assertNot(instrument_span_processor_tail_sampler:should_keep(WithoutAttr, State)),

  ok.

health_check_dropped_test(_Config) ->
  State = make_state(#{
    always_drop => [{attribute, <<"health_check">>, true}],
    default_ratio => 1.0  %% Keep everything else
  }),

  %% Health check span should be dropped
  HealthCheck = make_span(<<"health">>, #{
    attributes => #{<<"health_check">> => true}
  }),
  ?assertNot(instrument_span_processor_tail_sampler:should_keep(HealthCheck, State)),

  %% Regular span should be kept
  Regular = make_span(<<"regular">>, #{}),
  ?assert(instrument_span_processor_tail_sampler:should_keep(Regular, State)),

  ok.

probability_sampling_test(_Config) ->
  %% Test with 0% ratio - should drop all non-matching
  State0 = make_state(#{default_ratio => 0.0}),
  Span = make_span(<<"test">>, #{}),
  ?assertNot(instrument_span_processor_tail_sampler:should_keep(Span, State0)),

  %% Test with 100% ratio - should keep all
  State100 = make_state(#{default_ratio => 1.0}),
  ?assert(instrument_span_processor_tail_sampler:should_keep(Span, State100)),

  %% Test probabilistic behavior with consistent trace ID
  %% Same span should always get same decision
  State50 = make_state(#{default_ratio => 0.5}),
  Decision1 = instrument_span_processor_tail_sampler:should_keep(Span, State50),
  Decision2 = instrument_span_processor_tail_sampler:should_keep(Span, State50),
  ?assertEqual(Decision1, Decision2),

  ok.

rule_priority_test(_Config) ->
  %% always_keep should beat always_drop
  State = make_state(#{
    always_keep => [{status, error}],
    always_drop => [{attribute, <<"noisy">>, true}],
    default_ratio => 0.0
  }),

  %% Span that matches both keep and drop rules
  BothSpan = make_span(<<"both">>, #{
    status => {error, <<"err">>},
    attributes => #{<<"noisy">> => true}
  }),

  %% Should be kept because always_keep is checked first
  ?assert(instrument_span_processor_tail_sampler:should_keep(BothSpan, State)),

  %% Span that only matches drop
  DropSpan = make_span(<<"drop">>, #{
    status => ok,
    attributes => #{<<"noisy">> => true}
  }),
  ?assertNot(instrument_span_processor_tail_sampler:should_keep(DropSpan, State)),

  ok.

exception_event_detected_test(_Config) ->
  State = make_state(#{
    always_keep => [has_exception],
    default_ratio => 0.0
  }),

  %% Span with exception event
  ExceptionSpan = make_span(<<"exception">>, #{
    events => [#span_event{name = <<"exception">>, timestamp = 0, attributes = #{}}]
  }),
  ?assert(instrument_span_processor_tail_sampler:should_keep(ExceptionSpan, State)),

  %% Span without exception
  NormalSpan = make_span(<<"normal">>, #{}),
  ?assertNot(instrument_span_processor_tail_sampler:should_keep(NormalSpan, State)),

  %% Span with different event
  OtherEvent = make_span(<<"other">>, #{
    events => [#span_event{name = <<"something_else">>, timestamp = 0, attributes = #{}}]
  }),
  ?assertNot(instrument_span_processor_tail_sampler:should_keep(OtherEvent, State)),

  ok.

has_event_match_test(_Config) ->
  State = make_state(#{
    always_keep => [{has_event, <<"retry">>}],
    default_ratio => 0.0
  }),

  %% Span with matching event
  RetrySpan = make_span(<<"retry_span">>, #{
    events => [
      #span_event{name = <<"attempt">>, timestamp = 0, attributes = #{}},
      #span_event{name = <<"retry">>, timestamp = 1, attributes = #{}}
    ]
  }),
  ?assert(instrument_span_processor_tail_sampler:should_keep(RetrySpan, State)),

  %% Span without matching event
  NoRetrySpan = make_span(<<"no_retry">>, #{
    events => [#span_event{name = <<"attempt">>, timestamp = 0, attributes = #{}}]
  }),
  ?assertNot(instrument_span_processor_tail_sampler:should_keep(NoRetrySpan, State)),

  ok.

duration_comparison_operators_test(_Config) ->
  %% Test all comparison operators
  Span100ms = make_span(<<"span">>, #{duration_ns => 100 * 1000000}),

  %% Greater than
  StateGT = make_state(#{always_keep => [{duration_ms, '>', 99}], default_ratio => 0.0}),
  ?assert(instrument_span_processor_tail_sampler:should_keep(Span100ms, StateGT)),

  StateGTFail = make_state(#{always_keep => [{duration_ms, '>', 100}], default_ratio => 0.0}),
  ?assertNot(instrument_span_processor_tail_sampler:should_keep(Span100ms, StateGTFail)),

  %% Less than
  StateLT = make_state(#{always_keep => [{duration_ms, '<', 101}], default_ratio => 0.0}),
  ?assert(instrument_span_processor_tail_sampler:should_keep(Span100ms, StateLT)),

  %% Greater than or equal
  StateGTE = make_state(#{always_keep => [{duration_ms, '>=', 100}], default_ratio => 0.0}),
  ?assert(instrument_span_processor_tail_sampler:should_keep(Span100ms, StateGTE)),

  %% Less than or equal
  StateLTE = make_state(#{always_keep => [{duration_ms, '<=', 100}], default_ratio => 0.0}),
  ?assert(instrument_span_processor_tail_sampler:should_keep(Span100ms, StateLTE)),

  ok.

non_recording_spans_ignored_test(_Config) ->
  Self = self(),
  setup_mock_exporter(Self),

  ok = instrument_span_processor:register(instrument_span_processor_tail_sampler, #{
    always_keep => [{status, error}],
    default_ratio => 1.0,
    exporter => mock_tail_exporter,
    exporter_config => #{}
  }),

  %% Non-recording span should be ignored
  NonRecordingSpan = make_span(<<"non_recording">>, #{is_recording => false}),
  instrument_span_processor_tail_sampler:on_end(NonRecordingSpan),

  receive
    {exported, _} -> ct:fail(non_recording_span_should_be_ignored)
  after 100 ->
    ok
  end,

  cleanup_mock_exporter(),
  ok.

no_exporter_configured_test(_Config) ->
  %% Should work without exporter (just filtering)
  {ok, _State} = instrument_span_processor_tail_sampler:init(#{
    always_keep => [{status, error}],
    default_ratio => 0.5
  }),

  %% on_end should not crash
  Span = make_span(<<"test">>, #{status => {error, <<"err">>}}),
  ok = instrument_span_processor_tail_sampler:on_end(Span),

  %% Cleanup
  instrument_span_processor_tail_sampler:shutdown(),
  ok.

invalid_rule_rejected_test(_Config) ->
  %% Invalid status value
  {error, {invalid_rule, _}} = instrument_span_processor_tail_sampler:init(#{
    always_keep => [{status, invalid}]
  }),

  %% Invalid duration operator
  {error, {invalid_rule, _}} = instrument_span_processor_tail_sampler:init(#{
    always_keep => [{duration_ms, '==', 100}]
  }),

  %% Invalid duration value
  {error, {invalid_rule, _}} = instrument_span_processor_tail_sampler:init(#{
    always_keep => [{duration_ms, '>', -10}]
  }),

  %% Unknown rule
  {error, {invalid_rule, _}} = instrument_span_processor_tail_sampler:init(#{
    always_keep => [{unknown_rule, foo}]
  }),

  ok.

integration_with_tracer_test(_Config) ->
  Self = self(),
  setup_mock_exporter(Self),

  ok = instrument_span_processor:register(instrument_span_processor_tail_sampler, #{
    always_keep => [{status, error}, {duration_ms, '>', 50}],
    default_ratio => 0.0,
    exporter => mock_tail_exporter,
    exporter_config => #{}
  }),

  %% This should be dropped (ok status, fast)
  instrument_tracer:with_span(<<"fast_ok">>, fun() ->
    instrument_tracer:set_status(ok)
  end),

  receive
    {exported, [#span{name = <<"fast_ok">>}]} -> ct:fail(fast_ok_should_be_dropped)
  after 100 ->
    ok
  end,

  %% This should be kept (error status)
  instrument_tracer:with_span(<<"error_span">>, fun() ->
    instrument_tracer:set_status(error, <<"test error">>)
  end),

  receive
    {exported, [#span{name = <<"error_span">>}]} -> ok
  after 1000 ->
    ct:fail(error_span_not_exported)
  end,

  %% This should be kept (slow)
  instrument_tracer:with_span(<<"slow_span">>, fun() ->
    timer:sleep(60),
    instrument_tracer:set_status(ok)
  end),

  receive
    {exported, [#span{name = <<"slow_span">>}]} -> ok
  after 1000 ->
    ct:fail(slow_span_not_exported)
  end,

  cleanup_mock_exporter(),
  ok.

%% Test that spans with undefined end_time skip duration rules gracefully
undefined_end_time_test(_Config) ->
  State = make_state(#{
    always_keep => [{duration_ms, '>', 100}],
    default_ratio => 0.0  %% Drop spans that don't match rules
  }),

  %% Create a span with undefined end_time (malformed)
  MalformedSpan = #span{
    name = <<"malformed_span">>,
    ctx = #span_ctx{
      trace_id = crypto:strong_rand_bytes(16),
      span_id = crypto:strong_rand_bytes(8),
      trace_flags = 1
    },
    parent_ctx = undefined,
    kind = internal,
    start_time = erlang:monotonic_time(nanosecond),
    end_time = undefined,  %% Undefined end_time
    attributes = #{},
    events = [],
    links = [],
    status = unset,
    is_recording = true
  },

  %% Duration rule should not match (returns false, doesn't crash)
  ?assertNot(instrument_span_processor_tail_sampler:should_keep(MalformedSpan, State)),

  %% Also test with duration rule that would match if end_time was valid
  StateFast = make_state(#{
    always_keep => [{duration_ms, '<', 1000}],  %% Would match most spans
    default_ratio => 0.0
  }),

  %% Should still not match since end_time is undefined
  ?assertNot(instrument_span_processor_tail_sampler:should_keep(MalformedSpan, StateFast)),

  ok.

%% ============================================================================
%% Helper Functions
%% ============================================================================

make_span(Name, Opts) ->
  Now = erlang:monotonic_time(nanosecond),
  DurationNs = maps:get(duration_ns, Opts, 10 * 1000000),  %% Default 10ms

  #span{
    name = Name,
    ctx = #span_ctx{
      trace_id = crypto:strong_rand_bytes(16),
      span_id = crypto:strong_rand_bytes(8),
      trace_flags = 1
    },
    parent_ctx = undefined,
    kind = internal,
    start_time = Now - DurationNs,
    end_time = Now,
    attributes = maps:get(attributes, Opts, #{}),
    events = maps:get(events, Opts, []),
    links = [],
    status = maps:get(status, Opts, unset),
    is_recording = maps:get(is_recording, Opts, true)
  }.

%% Initialize processor and get state from persistent_term for testing
make_state(Opts) ->
  %% Initialize with config to populate persistent_term
  Config = #{
    always_keep => maps:get(always_keep, Opts, []),
    always_drop => maps:get(always_drop, Opts, []),
    default_ratio => maps:get(default_ratio, Opts, 0.01)
  },
  {ok, State} = instrument_span_processor_tail_sampler:init(Config),
  State.

setup_mock_exporter(Pid) ->
  meck:new(mock_tail_exporter, [non_strict]),
  meck:expect(mock_tail_exporter, init, fun(_) -> {ok, #{pid => Pid}} end),
  meck:expect(mock_tail_exporter, export, fun(Spans, #{pid := P} = State) ->
    P ! {exported, Spans},
    {ok, State}
  end),
  meck:expect(mock_tail_exporter, shutdown, fun(_) -> ok end),
  meck:expect(mock_tail_exporter, force_flush, fun(_) -> ok end),
  ok.

cleanup_mock_exporter() ->
  instrument_span_processor:unregister(instrument_span_processor_tail_sampler),
  meck:unload(mock_tail_exporter),
  ok.
