%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_sampler_SUITE).
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
  always_on_sampler_test/1,
  always_off_sampler_test/1,
  probability_sampler_test/1,
  probability_sampler_deterministic_test/1,
  parent_based_sampler_root_test/1,
  parent_based_sampler_local_parent_test/1,
  parent_based_sampler_remote_parent_test/1,
  set_sampler_test/1,
  sampler_integration_test/1,
  sampler_attributes_test/1,
  %% New tests
  probability_distribution_test/1,
  parent_sampled_propagation_test/1,
  parent_not_sampled_propagation_test/1,
  invalid_probability_test/1,
  sampling_decision_attributes_test/1,
  concurrent_sampling_test/1
]).

all() ->
  [
    always_on_sampler_test,
    always_off_sampler_test,
    probability_sampler_test,
    probability_sampler_deterministic_test,
    parent_based_sampler_root_test,
    parent_based_sampler_local_parent_test,
    parent_based_sampler_remote_parent_test,
    set_sampler_test,
    sampler_integration_test,
    sampler_attributes_test,
    %% New tests
    probability_distribution_test,
    parent_sampled_propagation_test,
    parent_not_sampled_propagation_test,
    invalid_probability_test,
    sampling_decision_attributes_test,
    concurrent_sampling_test
  ].

init_per_suite(Config) ->
  _ = application:ensure_all_started(crypto),
  ok = application:start(instrument),
  Config.

end_per_suite(_Config) ->
  ok = application:stop(instrument),
  ok.

init_per_testcase(_TestCase, Config) ->
  %% Reset to default sampler
  instrument_sampler:set_sampler(instrument_sampler_always_on),
  Config.

end_per_testcase(_TestCase, _Config) ->
  %% Reset to default sampler
  instrument_sampler:set_sampler(instrument_sampler_always_on),
  ok.

%% ============================================================================
%% Test Cases
%% ============================================================================

always_on_sampler_test(_Config) ->
  TraceId = instrument_id:generate_trace_id(),
  Result = instrument_sampler_always_on:should_sample(
    #{}, TraceId, <<"test_span">>, internal, #{}, [], undefined
  ),
  ?assertEqual(record_and_sample, Result#sampling_result.decision),
  ?assertEqual(#{}, Result#sampling_result.attributes),
  ?assertEqual([], Result#sampling_result.trace_state),
  ?assertEqual(<<"AlwaysOnSampler">>, instrument_sampler_always_on:get_description(#{})),
  ok.

always_off_sampler_test(_Config) ->
  TraceId = instrument_id:generate_trace_id(),
  Result = instrument_sampler_always_off:should_sample(
    #{}, TraceId, <<"test_span">>, internal, #{}, [], undefined
  ),
  ?assertEqual(drop, Result#sampling_result.decision),
  ?assertEqual(#{}, Result#sampling_result.attributes),
  ?assertEqual([], Result#sampling_result.trace_state),
  ?assertEqual(<<"AlwaysOffSampler">>, instrument_sampler_always_off:get_description(#{})),
  ok.

probability_sampler_test(_Config) ->
  %% Test ratio 0.0 - should never sample
  TraceId1 = instrument_id:generate_trace_id(),
  Result1 = instrument_sampler_probability:should_sample(
    #{ratio => 0.0}, TraceId1, <<"test_span">>, internal, #{}, [], undefined
  ),
  ?assertEqual(drop, Result1#sampling_result.decision),

  %% Test ratio 1.0 - should always sample
  TraceId2 = instrument_id:generate_trace_id(),
  Result2 = instrument_sampler_probability:should_sample(
    #{ratio => 1.0}, TraceId2, <<"test_span">>, internal, #{}, [], undefined
  ),
  ?assertEqual(record_and_sample, Result2#sampling_result.decision),

  %% Test description
  Desc = instrument_sampler_probability:get_description(#{ratio => 0.5}),
  ?assertMatch(<<"TraceIdRatioBased{", _/binary>>, Desc),
  ok.

probability_sampler_deterministic_test(_Config) ->
  %% Same trace ID should always produce same result
  TraceId = instrument_id:generate_trace_id(),
  Config = #{ratio => 0.5},

  Result1 = instrument_sampler_probability:should_sample(
    Config, TraceId, <<"span1">>, internal, #{}, [], undefined
  ),
  Result2 = instrument_sampler_probability:should_sample(
    Config, TraceId, <<"span2">>, server, #{key => value}, [], undefined
  ),
  ?assertEqual(Result1#sampling_result.decision, Result2#sampling_result.decision),
  ok.

parent_based_sampler_root_test(_Config) ->
  %% Test root span (no parent) uses root sampler
  TraceId = instrument_id:generate_trace_id(),

  %% Default root sampler is always_on
  Result1 = instrument_sampler_parent_based:should_sample(
    #{}, TraceId, <<"test_span">>, internal, #{}, [], undefined
  ),
  ?assertEqual(record_and_sample, Result1#sampling_result.decision),

  %% Custom root sampler
  Result2 = instrument_sampler_parent_based:should_sample(
    #{root => instrument_sampler_always_off, root_config => #{}},
    TraceId, <<"test_span">>, internal, #{}, [], undefined
  ),
  ?assertEqual(drop, Result2#sampling_result.decision),
  ok.

parent_based_sampler_local_parent_test(_Config) ->
  TraceId = instrument_id:generate_trace_id(),
  SpanId = instrument_id:generate_span_id(),

  %% Sampled local parent - child should be sampled
  SampledParent = #span_ctx{
    trace_id = TraceId,
    span_id = SpanId,
    trace_flags = 1,
    is_remote = false
  },
  Result1 = instrument_sampler_parent_based:should_sample(
    #{}, TraceId, <<"child_span">>, internal, #{}, [], SampledParent
  ),
  ?assertEqual(record_and_sample, Result1#sampling_result.decision),

  %% Not sampled local parent - child should not be sampled
  NotSampledParent = #span_ctx{
    trace_id = TraceId,
    span_id = SpanId,
    trace_flags = 0,
    is_remote = false
  },
  Result2 = instrument_sampler_parent_based:should_sample(
    #{}, TraceId, <<"child_span">>, internal, #{}, [], NotSampledParent
  ),
  ?assertEqual(drop, Result2#sampling_result.decision),
  ok.

parent_based_sampler_remote_parent_test(_Config) ->
  TraceId = instrument_id:generate_trace_id(),
  SpanId = instrument_id:generate_span_id(),

  %% Sampled remote parent
  SampledRemoteParent = #span_ctx{
    trace_id = TraceId,
    span_id = SpanId,
    trace_flags = 1,
    is_remote = true
  },
  Result1 = instrument_sampler_parent_based:should_sample(
    #{}, TraceId, <<"child_span">>, internal, #{}, [], SampledRemoteParent
  ),
  ?assertEqual(record_and_sample, Result1#sampling_result.decision),

  %% Not sampled remote parent
  NotSampledRemoteParent = #span_ctx{
    trace_id = TraceId,
    span_id = SpanId,
    trace_flags = 0,
    is_remote = true
  },
  Result2 = instrument_sampler_parent_based:should_sample(
    #{}, TraceId, <<"child_span">>, internal, #{}, [], NotSampledRemoteParent
  ),
  ?assertEqual(drop, Result2#sampling_result.decision),
  ok.

set_sampler_test(_Config) ->
  %% Set always_off sampler
  ok = instrument_sampler:set_sampler(instrument_sampler_always_off),
  ?assertEqual(instrument_sampler_always_off, instrument_sampler:get_sampler()),
  ?assertEqual(<<"AlwaysOffSampler">>, instrument_sampler:get_description()),

  %% Set probability sampler with config
  ok = instrument_sampler:set_sampler(instrument_sampler_probability, #{ratio => 0.25}),
  ?assertEqual(instrument_sampler_probability, instrument_sampler:get_sampler()),

  %% Verify description includes ratio
  Desc = instrument_sampler:get_description(),
  ?assertMatch(<<"TraceIdRatioBased{", _/binary>>, Desc),

  %% Reset to always_on
  ok = instrument_sampler:set_sampler(instrument_sampler_always_on),
  ?assertEqual(instrument_sampler_always_on, instrument_sampler:get_sampler()),
  ok.

sampler_integration_test(_Config) ->
  %% Test that sampler affects span creation
  instrument_sampler:set_sampler(instrument_sampler_always_off),

  Span = instrument_tracer:start_span(<<"sampler_test">>),
  ?assertEqual(false, Span#span.is_recording),
  ?assertEqual(0, (Span#span.ctx)#span_ctx.trace_flags),
  instrument_tracer:end_span(Span),

  %% Now with always_on
  instrument_sampler:set_sampler(instrument_sampler_always_on),

  Span2 = instrument_tracer:start_span(<<"sampler_test2">>),
  ?assertEqual(true, Span2#span.is_recording),
  ?assertEqual(1, (Span2#span.ctx)#span_ctx.trace_flags),
  instrument_tracer:end_span(Span2),
  ok.

sampler_attributes_test(_Config) ->
  %% Test that trace_state is preserved from parent
  ParentCtx = #span_ctx{
    trace_id = instrument_id:generate_trace_id(),
    span_id = instrument_id:generate_span_id(),
    trace_flags = 1,
    trace_state = [{<<"vendor">>, <<"value">>}],
    is_remote = false
  },

  Result = instrument_sampler_always_on:should_sample(
    #{}, ParentCtx#span_ctx.trace_id, <<"child">>, internal, #{}, [], ParentCtx
  ),
  ?assertEqual([{<<"vendor">>, <<"value">>}], Result#sampling_result.trace_state),
  ok.

%% ============================================================================
%% New Test Cases
%% ============================================================================

probability_distribution_test(_Config) ->
  %% Test that probability sampler produces approximately correct ratio
  Config = #{ratio => 0.5},
  NumSamples = 10000,

  Results = lists:map(fun(_) ->
    TraceId = instrument_id:generate_trace_id(),
    Result = instrument_sampler_probability:should_sample(
      Config, TraceId, <<"test">>, internal, #{}, [], undefined
    ),
    case Result#sampling_result.decision of
      record_and_sample -> 1;
      _ -> 0
    end
  end, lists:seq(1, NumSamples)),

  Sampled = lists:sum(Results),
  Ratio = Sampled / NumSamples,

  %% Allow 10% tolerance
  ?assert(Ratio > 0.4 andalso Ratio < 0.6),
  ok.

parent_sampled_propagation_test(_Config) ->
  %% When parent is sampled, child should be sampled
  TraceId = instrument_id:generate_trace_id(),
  SpanId = instrument_id:generate_span_id(),

  SampledParent = #span_ctx{
    trace_id = TraceId,
    span_id = SpanId,
    trace_flags = 1,  %% Sampled
    is_remote = false
  },

  %% Test with parent-based sampler
  Result = instrument_sampler_parent_based:should_sample(
    #{}, TraceId, <<"child">>, internal, #{}, [], SampledParent
  ),
  ?assertEqual(record_and_sample, Result#sampling_result.decision),
  ok.

parent_not_sampled_propagation_test(_Config) ->
  %% When parent is not sampled, child should not be sampled
  TraceId = instrument_id:generate_trace_id(),
  SpanId = instrument_id:generate_span_id(),

  NotSampledParent = #span_ctx{
    trace_id = TraceId,
    span_id = SpanId,
    trace_flags = 0,  %% Not sampled
    is_remote = false
  },

  Result = instrument_sampler_parent_based:should_sample(
    #{}, TraceId, <<"child">>, internal, #{}, [], NotSampledParent
  ),
  ?assertEqual(drop, Result#sampling_result.decision),
  ok.

invalid_probability_test(_Config) ->
  %% Test boundary conditions for probability sampler
  TraceId = instrument_id:generate_trace_id(),

  %% Ratio of 0 should never sample
  Result0 = instrument_sampler_probability:should_sample(
    #{ratio => 0.0}, TraceId, <<"test">>, internal, #{}, [], undefined
  ),
  ?assertEqual(drop, Result0#sampling_result.decision),

  %% Ratio of 1 should always sample
  Result1 = instrument_sampler_probability:should_sample(
    #{ratio => 1.0}, TraceId, <<"test">>, internal, #{}, [], undefined
  ),
  ?assertEqual(record_and_sample, Result1#sampling_result.decision),
  ok.

sampling_decision_attributes_test(_Config) ->
  %% Test that sampling result contains expected fields
  TraceId = instrument_id:generate_trace_id(),

  Result = instrument_sampler_always_on:should_sample(
    #{}, TraceId, <<"test">>, server, #{attr => value}, [], undefined
  ),

  %% Verify result structure
  ?assert(is_record(Result, sampling_result)),
  ?assertEqual(record_and_sample, Result#sampling_result.decision),
  ?assert(is_map(Result#sampling_result.attributes)),
  ?assert(is_list(Result#sampling_result.trace_state)),
  ok.

concurrent_sampling_test(_Config) ->
  %% Test thread-safe sampling with concurrent access
  Config = #{ratio => 0.5},
  Self = self(),
  NumProcesses = 100,
  SamplesPerProcess = 100,

  %% Spawn processes that sample concurrently
  Pids = [spawn_link(fun() ->
    Results = lists:map(fun(_) ->
      TraceId = instrument_id:generate_trace_id(),
      Result = instrument_sampler_probability:should_sample(
        Config, TraceId, <<"test">>, internal, #{}, [], undefined
      ),
      Result#sampling_result.decision
    end, lists:seq(1, SamplesPerProcess)),
    Self ! {self(), Results}
  end) || _ <- lists:seq(1, NumProcesses)],

  %% Collect results
  AllResults = lists:foldl(fun(Pid, Acc) ->
    receive {Pid, Results} -> Acc ++ Results end
  end, [], Pids),

  %% Verify we got all results and they're valid decisions
  ?assertEqual(NumProcesses * SamplesPerProcess, length(AllResults)),
  ?assert(lists:all(fun(D) -> D =:= record_and_sample orelse D =:= drop end, AllResults)),
  ok.
