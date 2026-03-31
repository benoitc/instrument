%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc OpenTelemetry Sampler behavior and registry.
%%
%% Samplers determine whether a span should be sampled (recorded and exported)
%% based on various criteria like trace ID, parent context, and span attributes.
%%
%% == Built-in Samplers ==
%% - `instrument_sampler_always_on' - Always sample
%% - `instrument_sampler_always_off' - Never sample
%% - `instrument_sampler_probability' - Probability-based sampling
%% - `instrument_sampler_parent_based' - Defer to parent's sampling decision
%%
%% == Example Usage ==
%% ```
%% %% Set global sampler
%% instrument_sampler:set_sampler(instrument_sampler_probability, #{ratio => 0.5}).
%%
%% %% Make a sampling decision
%% Result = instrument_sampler:should_sample(TraceId, SpanName, SpanKind, Attributes, Links, ParentCtx).
%% '''
-module(instrument_sampler).
-author("benoitc").

-include("instrument_otel.hrl").

%% API
-export([
  should_sample/6,
  set_sampler/1,
  set_sampler/2,
  get_sampler/0,
  get_description/0
]).

-define(SAMPLER_KEY, '$instrument_sampler').
-define(SAMPLER_CONFIG_KEY, '$instrument_sampler_config').

-type sampling_decision() :: drop | record_only | record_and_sample.
-type sampling_result() :: #sampling_result{}.
-type sampler_config() :: map().

-export_type([sampling_decision/0, sampling_result/0, sampler_config/0]).

%% Behavior callbacks for sampler modules.
-callback should_sample(
  Config :: sampler_config(),
  TraceId :: binary(),
  SpanName :: binary(),
  SpanKind :: atom(),
  Attributes :: map(),
  Links :: list(),
  ParentCtx :: #span_ctx{} | undefined
) -> #sampling_result{}.

-callback get_description(Config :: sampler_config()) -> binary().

%% @doc Makes a sampling decision for a new span.
%%
%% Returns a sampling_result record containing:
%% - decision: drop | record_only | record_and_sample
%% - attributes: additional attributes to add to the span
%% - trace_state: updated trace state
-spec should_sample(
  TraceId :: binary(),
  SpanName :: binary(),
  SpanKind :: atom(),
  Attributes :: map(),
  Links :: list(),
  ParentCtx :: #span_ctx{} | undefined
) -> sampling_result().
should_sample(TraceId, SpanName, SpanKind, Attributes, Links, ParentCtx) ->
  {Sampler, Config} = get_sampler_with_config(),
  Sampler:should_sample(Config, TraceId, SpanName, SpanKind, Attributes, Links, ParentCtx).

%% @doc Sets the global sampler module.
-spec set_sampler(module()) -> ok.
set_sampler(SamplerModule) ->
  set_sampler(SamplerModule, #{}).

%% @doc Sets the global sampler module with configuration.
-spec set_sampler(module(), sampler_config()) -> ok.
set_sampler(SamplerModule, Config) when is_atom(SamplerModule), is_map(Config) ->
  persistent_term:put(?SAMPLER_KEY, SamplerModule),
  persistent_term:put(?SAMPLER_CONFIG_KEY, Config),
  ok.

%% @doc Gets the current global sampler module.
-spec get_sampler() -> module().
get_sampler() ->
  persistent_term:get(?SAMPLER_KEY, instrument_sampler_always_on).

%% @doc Gets the description of the current sampler.
-spec get_description() -> binary().
get_description() ->
  {Sampler, Config} = get_sampler_with_config(),
  Sampler:get_description(Config).

%% ============================================================================
%% Internal Functions
%% ============================================================================

get_sampler_with_config() ->
  Sampler = persistent_term:get(?SAMPLER_KEY, instrument_sampler_always_on),
  Config = persistent_term:get(?SAMPLER_CONFIG_KEY, #{}),
  {Sampler, Config}.
