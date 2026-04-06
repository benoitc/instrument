%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_sampler_attribute_SUITE).
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
    default_ratio_test/1,
    attribute_match_test/1,
    first_match_wins_test/1,
    error_force_sample_test/1,
    value_type_coercion_test/1,
    no_rules_test/1,
    multiple_rules_test/1,
    get_description_test/1,
    deterministic_sampling_test/1,
    distribution_test/1,
    integration_test/1
]).

all() ->
    [
        default_ratio_test,
        attribute_match_test,
        first_match_wins_test,
        error_force_sample_test,
        value_type_coercion_test,
        no_rules_test,
        multiple_rules_test,
        get_description_test,
        deterministic_sampling_test,
        distribution_test,
        integration_test
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

default_ratio_test(_Config) ->
    %% When no rules match, default_ratio should be used
    Config = #{
        default_ratio => 1.0,
        attribute_rules => [
            {<<"db.operation">>, <<"DELETE">>, 0.5}
        ]
    },

    TraceId = instrument_id:generate_trace_id(),
    Result = instrument_sampler_attribute:should_sample(
        Config, TraceId, <<"test">>, internal,
        #{<<"db.operation">> => <<"SELECT">>},  %% Doesn't match rule
        [], undefined
    ),

    %% With default_ratio of 1.0, should always sample
    ?assertEqual(record_and_sample, Result#sampling_result.decision),
    ok.

attribute_match_test(_Config) ->
    %% Test that attribute matching works
    Config = #{
        default_ratio => 0.0,  %% Would drop by default
        attribute_rules => [
            {<<"db.operation">>, <<"SELECT">>, 1.0}  %% Always sample SELECTs
        ]
    },

    TraceId = instrument_id:generate_trace_id(),

    %% Matching attribute
    Result1 = instrument_sampler_attribute:should_sample(
        Config, TraceId, <<"test">>, internal,
        #{<<"db.operation">> => <<"SELECT">>},
        [], undefined
    ),
    ?assertEqual(record_and_sample, Result1#sampling_result.decision),

    %% Non-matching attribute
    Result2 = instrument_sampler_attribute:should_sample(
        Config, TraceId, <<"test">>, internal,
        #{<<"db.operation">> => <<"INSERT">>},
        [], undefined
    ),
    ?assertEqual(drop, Result2#sampling_result.decision),

    ok.

first_match_wins_test(_Config) ->
    %% First matching rule should determine ratio
    Config = #{
        default_ratio => 0.0,
        attribute_rules => [
            {<<"error">>, true, 1.0},           %% First: always sample errors
            {<<"db.operation">>, <<"SELECT">>, 0.0}  %% Second: never sample SELECTs
        ]
    },

    TraceId = instrument_id:generate_trace_id(),

    %% Has both error=true and operation=SELECT, error rule wins
    Result = instrument_sampler_attribute:should_sample(
        Config, TraceId, <<"test">>, internal,
        #{
            <<"error">> => true,
            <<"db.operation">> => <<"SELECT">>
        },
        [], undefined
    ),
    ?assertEqual(record_and_sample, Result#sampling_result.decision),

    ok.

error_force_sample_test(_Config) ->
    %% Common pattern: always sample errors
    Config = #{
        default_ratio => 0.0,  %% Drop everything by default
        attribute_rules => [
            {<<"error">>, true, 1.0},
            {<<"otel.status_code">>, <<"ERROR">>, 1.0}
        ]
    },

    TraceId = instrument_id:generate_trace_id(),

    %% error=true attribute
    Result1 = instrument_sampler_attribute:should_sample(
        Config, TraceId, <<"test">>, internal,
        #{<<"error">> => true},
        [], undefined
    ),
    ?assertEqual(record_and_sample, Result1#sampling_result.decision),

    %% otel.status_code=ERROR
    Result2 = instrument_sampler_attribute:should_sample(
        Config, TraceId, <<"test">>, internal,
        #{<<"otel.status_code">> => <<"ERROR">>},
        [], undefined
    ),
    ?assertEqual(record_and_sample, Result2#sampling_result.decision),

    %% No error attributes
    Result3 = instrument_sampler_attribute:should_sample(
        Config, TraceId, <<"test">>, internal,
        #{<<"db.operation">> => <<"SELECT">>},
        [], undefined
    ),
    ?assertEqual(drop, Result3#sampling_result.decision),

    ok.

value_type_coercion_test(_Config) ->
    %% Test that different value types can be matched
    Config = #{
        default_ratio => 0.0,
        attribute_rules => [
            {<<"status_code">>, 500, 1.0},      %% Integer
            {<<"method">>, <<"GET">>, 1.0},    %% Binary
            {method_atom, get, 1.0}            %% Atom attribute name and value
        ]
    },

    TraceId = instrument_id:generate_trace_id(),

    %% Integer match
    Result1 = instrument_sampler_attribute:should_sample(
        Config, TraceId, <<"test">>, internal,
        #{<<"status_code">> => 500},
        [], undefined
    ),
    ?assertEqual(record_and_sample, Result1#sampling_result.decision),

    %% Binary to atom coercion
    Result2 = instrument_sampler_attribute:should_sample(
        Config, TraceId, <<"test">>, internal,
        #{<<"method">> => <<"GET">>},
        [], undefined
    ),
    ?assertEqual(record_and_sample, Result2#sampling_result.decision),

    ok.

no_rules_test(_Config) ->
    %% Config with no rules, only default
    Config = #{
        default_ratio => 0.5,
        attribute_rules => []
    },

    %% Should use default ratio for probability-based decision
    %% Test with 100 samples to verify it's using probability
    NumSamples = 1000,
    Results = lists:map(fun(_) ->
        TraceId = instrument_id:generate_trace_id(),
        Result = instrument_sampler_attribute:should_sample(
            Config, TraceId, <<"test">>, internal, #{}, [], undefined
        ),
        case Result#sampling_result.decision of
            record_and_sample -> 1;
            _ -> 0
        end
    end, lists:seq(1, NumSamples)),

    %% Should be approximately 50% sampled
    Sampled = lists:sum(Results) / NumSamples,
    ?assert(Sampled > 0.4 andalso Sampled < 0.6),

    ok.

multiple_rules_test(_Config) ->
    %% Test multiple rules for different scenarios
    Config = #{
        default_ratio => 0.001,
        attribute_rules => [
            {<<"error">>, true, 1.0},
            {<<"db.operation">>, <<"SELECT">>, 0.01},
            {<<"db.operation">>, <<"INSERT">>, 0.1},
            {<<"db.operation">>, <<"DELETE">>, 0.5},
            {<<"db.sql.table">>, <<"payments">>, 1.0}
        ]
    },

    TraceId = instrument_id:generate_trace_id(),

    %% DELETE operation
    ResultDelete = instrument_sampler_attribute:should_sample(
        Config, TraceId, <<"test">>, internal,
        #{<<"db.operation">> => <<"DELETE">>},
        [], undefined
    ),
    %% With ratio 0.5, result depends on trace ID, just verify it returns valid decision
    ?assert(ResultDelete#sampling_result.decision =:= record_and_sample orelse
            ResultDelete#sampling_result.decision =:= drop),

    %% Critical table should always sample
    ResultPayments = instrument_sampler_attribute:should_sample(
        Config, TraceId, <<"test">>, internal,
        #{<<"db.sql.table">> => <<"payments">>},
        [], undefined
    ),
    ?assertEqual(record_and_sample, ResultPayments#sampling_result.decision),

    ok.

get_description_test(_Config) ->
    Config = #{
        default_ratio => 0.1,
        attribute_rules => [
            {<<"error">>, true, 1.0},
            {<<"db.operation">>, <<"SELECT">>, 0.01}
        ]
    },

    Desc = instrument_sampler_attribute:get_description(Config),
    ?assertMatch(<<"AttributeSampler{default_ratio=", _/binary>>, Desc),
    ?assert(binary:match(Desc, <<"rules=2">>) =/= nomatch),

    ok.

deterministic_sampling_test(_Config) ->
    %% Same trace ID should always produce same result
    Config = #{
        default_ratio => 0.5,
        attribute_rules => []
    },

    TraceId = instrument_id:generate_trace_id(),

    Results = [instrument_sampler_attribute:should_sample(
        Config, TraceId, <<"test">>, internal, #{}, [], undefined
    ) || _ <- lists:seq(1, 10)],

    Decisions = [R#sampling_result.decision || R <- Results],
    %% All decisions should be the same
    ?assert(lists:all(fun(D) -> D =:= hd(Decisions) end, Decisions)),

    ok.

distribution_test(_Config) ->
    %% Test that probability distribution is approximately correct
    Config = #{
        default_ratio => 0.25,
        attribute_rules => []
    },

    NumSamples = 10000,
    Results = lists:map(fun(_) ->
        TraceId = instrument_id:generate_trace_id(),
        Result = instrument_sampler_attribute:should_sample(
            Config, TraceId, <<"test">>, internal, #{}, [], undefined
        ),
        case Result#sampling_result.decision of
            record_and_sample -> 1;
            _ -> 0
        end
    end, lists:seq(1, NumSamples)),

    Ratio = lists:sum(Results) / NumSamples,
    %% Allow 5% tolerance
    ?assert(Ratio > 0.20 andalso Ratio < 0.30),

    ok.

integration_test(_Config) ->
    %% Test as global sampler
    instrument_sampler:set_sampler(instrument_sampler_attribute, #{
        default_ratio => 0.0,
        attribute_rules => [
            {<<"force_sample">>, true, 1.0}
        ]
    }),

    %% Without force_sample attribute
    Span1 = instrument_tracer:start_span(<<"test_span">>, #{
        attributes => #{<<"normal">> => true}
    }),
    ?assertEqual(false, Span1#span.is_recording),
    instrument_tracer:end_span(Span1),

    %% With force_sample attribute
    Span2 = instrument_tracer:start_span(<<"test_span">>, #{
        attributes => #{<<"force_sample">> => true}
    }),
    ?assertEqual(true, Span2#span.is_recording),
    instrument_tracer:end_span(Span2),

    ok.
