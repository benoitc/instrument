%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Attribute-aware sampler for fine-grained sampling control.
%%
%% This sampler allows configuring sampling rates based on span attributes,
%% enabling sophisticated sampling strategies like:
%% - Lower sampling for high-volume read operations
%% - Higher sampling for writes and mutations
%% - Force sampling for critical tables/topics
%%
%% == IMPORTANT: Sampling Timing ==
%% Sampling decisions are made at span start, BEFORE your code executes.
%% Only attributes passed in the span options at creation time can influence
%% the sampling decision. Attributes set later via set_attribute/2 have NO
%% effect on sampling.
%%
%% For error sampling based on execution results, use tail-based sampling
%% or custom span processors instead of attribute rules.
%%
%% == Configuration ==
%% ```
%% instrument_sampler:set_sampler(instrument_sampler_attribute, #{
%%     default_ratio => 0.1,
%%     attribute_rules => [
%%         %% {AttributeName, Value, SamplingRatio}
%%         %% These attributes MUST be passed at span creation time
%%         {<<"db.operation">>, <<"SELECT">>, 0.01},
%%         {<<"db.operation">>, <<"DELETE">>, 0.5},
%%         {<<"db.sql.table">>, <<"audit_log">>, 1.0}
%%     ]
%% }).
%% '''
%%
%% == Rule Matching ==
%% - Rules are evaluated in order
%% - First matching rule determines the sampling rate
%% - If no rules match, default_ratio is used
%% - Attribute values can be binaries, atoms, integers, or booleans
%%
%% == Example Use Cases ==
%%
%% Database tracing:
%% ```
%% #{
%%     default_ratio => 0.001,  %% 0.1% baseline
%%     attribute_rules => [
%%         {<<"db.operation">>, <<"SELECT">>, 0.001},
%%         {<<"db.operation">>, <<"INSERT">>, 0.01},
%%         {<<"db.operation">>, <<"UPDATE">>, 0.01},
%%         {<<"db.operation">>, <<"DELETE">>, 0.05},
%%         {<<"db.sql.table">>, <<"payments">>, 1.0}
%%     ]
%% }
%% '''
%%
%% HTTP client tracing:
%% ```
%% #{
%%     default_ratio => 0.1,
%%     attribute_rules => [
%%         {<<"http.method">>, <<"GET">>, 0.01},
%%         {<<"http.method">>, <<"POST">>, 0.1}
%%     ]
%% }
%% '''
-module(instrument_sampler_attribute).
-author("benoitc").

-include("instrument_otel.hrl").

-behaviour(instrument_sampler).

-export([
    should_sample/7,
    get_description/1
]).

%% Maximum value for unsigned 64-bit integer used for probability calculation
-define(MAX_UINT64, 18446744073709551615).

-type attribute_rule() :: {binary() | atom(), term(), float()}.

-type config() :: #{
    default_ratio => float(),
    attribute_rules => [attribute_rule()]
}.

-export_type([config/0, attribute_rule/0]).

%% @doc Samples based on span attributes with configurable rules.
-spec should_sample(
    Config :: config(),
    TraceId :: binary(),
    SpanName :: binary(),
    SpanKind :: atom(),
    Attributes :: map(),
    Links :: list(),
    ParentCtx :: #span_ctx{} | undefined
) -> #sampling_result{}.
should_sample(Config, TraceId, _SpanName, _SpanKind, Attributes, _Links, ParentCtx) ->
    Rules = maps:get(attribute_rules, Config, []),
    DefaultRatio = maps:get(default_ratio, Config, 1.0),

    TraceState = case ParentCtx of
        #span_ctx{trace_state = TS} -> TS;
        undefined -> []
    end,

    Ratio = find_matching_rule(Rules, Attributes, DefaultRatio),
    Decision = probability_decision(TraceId, Ratio),

    #sampling_result{
        decision = Decision,
        attributes = #{},
        trace_state = TraceState
    }.

%% @doc Returns the sampler description.
-spec get_description(Config :: config()) -> binary().
get_description(Config) ->
    DefaultRatio = maps:get(default_ratio, Config, 1.0),
    Rules = maps:get(attribute_rules, Config, []),
    NumRules = length(Rules),
    iolist_to_binary(io_lib:format(
        "AttributeSampler{default_ratio=~.4f, rules=~B}",
        [DefaultRatio, NumRules]
    )).

%% ============================================================================
%% Internal Functions
%% ============================================================================

%% @private
%% Finds the first matching rule and returns its sampling ratio.
-spec find_matching_rule([attribute_rule()], map(), float()) -> float().
find_matching_rule([], _Attributes, Default) ->
    Default;
find_matching_rule([{AttrName, ExpectedValue, Ratio} | Rest], Attributes, Default) ->
    NormalizedName = normalize_attr_name(AttrName),
    case maps:get(NormalizedName, Attributes, undefined) of
        undefined ->
            find_matching_rule(Rest, Attributes, Default);
        ActualValue ->
            case values_match(ExpectedValue, ActualValue) of
                true -> Ratio;
                false -> find_matching_rule(Rest, Attributes, Default)
            end
    end.

%% @private
%% Normalizes attribute name to binary.
normalize_attr_name(Name) when is_binary(Name) -> Name;
normalize_attr_name(Name) when is_atom(Name) -> atom_to_binary(Name, utf8);
normalize_attr_name(Name) when is_list(Name) -> list_to_binary(Name).

%% @private
%% Compares values with type coercion.
values_match(Expected, Actual) when Expected =:= Actual -> true;
values_match(Expected, Actual) when is_binary(Expected), is_atom(Actual) ->
    Expected =:= atom_to_binary(Actual, utf8);
values_match(Expected, Actual) when is_atom(Expected), is_binary(Actual) ->
    atom_to_binary(Expected, utf8) =:= Actual;
values_match(Expected, Actual) when is_list(Expected), is_binary(Actual) ->
    list_to_binary(Expected) =:= Actual;
values_match(Expected, Actual) when is_binary(Expected), is_list(Actual) ->
    Expected =:= list_to_binary(Actual);
values_match(Expected, Actual) when is_integer(Expected), is_integer(Actual) ->
    Expected =:= Actual;
values_match(_, _) -> false.

%% @private
%% Makes probability-based sampling decision using trace ID.
-spec probability_decision(binary(), float()) -> drop | record_and_sample.
probability_decision(_TraceId, Ratio) when Ratio >= 1.0 ->
    record_and_sample;
probability_decision(_TraceId, Ratio) when Ratio =< 0.0 ->
    drop;
probability_decision(TraceId, Ratio) when is_binary(TraceId), byte_size(TraceId) =:= 16 ->
    %% Use lower 8 bytes of trace ID for deterministic sampling
    <<_:64, LowerBytes:64/unsigned-big>> = TraceId,
    Threshold = trunc(Ratio * ?MAX_UINT64),
    case LowerBytes < Threshold of
        true -> record_and_sample;
        false -> drop
    end;
probability_decision(_TraceId, _Ratio) ->
    %% Invalid trace ID, default to sampling
    record_and_sample.
