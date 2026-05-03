%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Probability-based sampler (TraceIdRatioBased).
%%
%% Samples a configurable percentage of traces based on their trace ID.
%% The sampling decision is deterministic: the same trace ID will always
%% produce the same sampling decision.
%%
%% == Configuration ==
%% - `ratio': A float between 0.0 and 1.0 (default: 1.0)
%%   - 0.0 means never sample
%%   - 1.0 means always sample
%%   - 0.5 means sample approximately 50% of traces
%%
%% == Example ==
%% ```
%% instrument_sampler:set_sampler(instrument_sampler_probability, #{ratio => 0.1}).
%% '''
-module(instrument_sampler_probability).
-author("benoitc").

-include("instrument_otel.hrl").

-behaviour(instrument_sampler).

-export([
  should_sample/7,
  get_description/1
]).

%% Maximum value for unsigned 64-bit integer used for probability calculation
-define(MAX_UINT64, 18446744073709551615).

%% @doc Samples based on trace ID probability.
-spec should_sample(
  Config :: map(),
  TraceId :: binary(),
  SpanName :: binary(),
  SpanKind :: atom(),
  Attributes :: map(),
  Links :: list(),
  ParentCtx :: #span_ctx{} | undefined
) -> #sampling_result{}.
should_sample(Config, TraceId, _SpanName, _SpanKind, _Attributes, _Links, ParentCtx) ->
  Ratio = maps:get(ratio, Config, 1.0),
  TraceState = case ParentCtx of
    #span_ctx{trace_state = TS} -> TS;
    undefined -> []
  end,
  Decision = case should_sample_trace_id(TraceId, Ratio) of
    true -> record_and_sample;
    false -> drop
  end,
  #sampling_result{
    decision = Decision,
    attributes = #{},
    trace_state = TraceState
  }.

%% @doc Returns the sampler description.
-spec get_description(Config :: map()) -> binary().
get_description(Config) ->
  Ratio = maps:get(ratio, Config, 1.0),
  iolist_to_binary(io_lib:format("TraceIdRatioBased{~.6f}", [Ratio])).

%% ============================================================================
%% Internal Functions
%% ============================================================================

%% @private
%% Determines if a trace ID should be sampled based on the ratio.
%% Uses the upper 8 bytes of the trace ID for deterministic sampling, in
%% line with the OTel reference (Java/Go/Python) implementations so that
%% samples are consistent across SDKs in the same trace.
should_sample_trace_id(_TraceId, Ratio) when Ratio >= 1.0 ->
  true;
should_sample_trace_id(_TraceId, Ratio) when Ratio =< 0.0 ->
  false;
should_sample_trace_id(TraceId, Ratio) when is_binary(TraceId), byte_size(TraceId) =:= 16 ->
  <<UpperBytes:64/unsigned-big, _:64>> = TraceId,
  Threshold = trunc(Ratio * ?MAX_UINT64),
  UpperBytes < Threshold;
should_sample_trace_id(_TraceId, _Ratio) ->
  %% Invalid trace ID, default to sampling
  true.
