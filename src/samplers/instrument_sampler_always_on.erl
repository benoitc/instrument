%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Always-on sampler that samples every span.
%%
%% This sampler returns record_and_sample for all spans, meaning all spans
%% will be recorded and exported.
-module(instrument_sampler_always_on).
-author("benoitc").

-include("instrument_otel.hrl").

-behaviour(instrument_sampler).

-export([
  should_sample/7,
  get_description/1
]).

%% @doc Always returns record_and_sample.
-spec should_sample(
  Config :: map(),
  TraceId :: binary(),
  SpanName :: binary(),
  SpanKind :: atom(),
  Attributes :: map(),
  Links :: list(),
  ParentCtx :: #span_ctx{} | undefined
) -> #sampling_result{}.
should_sample(_Config, _TraceId, _SpanName, _SpanKind, _Attributes, _Links, ParentCtx) ->
  TraceState = case ParentCtx of
    #span_ctx{trace_state = TS} -> TS;
    undefined -> []
  end,
  #sampling_result{
    decision = record_and_sample,
    attributes = #{},
    trace_state = TraceState
  }.

%% @doc Returns the sampler description.
-spec get_description(Config :: map()) -> binary().
get_description(_Config) ->
  <<"AlwaysOnSampler">>.
