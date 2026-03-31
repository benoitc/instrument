%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Parent-based sampler that defers to parent's sampling decision.
%%
%% This sampler makes decisions based on the parent span's sampling state:
%% - If parent is sampled, child is sampled
%% - If parent is not sampled, child is not sampled
%% - If no parent (root span), delegates to a configurable root sampler
%%
%% == Configuration ==
%% - `root': Sampler for root spans (default: instrument_sampler_always_on)
%% - `root_config': Configuration for root sampler (default: #{})
%% - `remote_parent_sampled': Sampler when remote parent is sampled (default: always_on)
%% - `remote_parent_not_sampled': Sampler when remote parent is not sampled (default: always_off)
%% - `local_parent_sampled': Sampler when local parent is sampled (default: always_on)
%% - `local_parent_not_sampled': Sampler when local parent is not sampled (default: always_off)
%%
%% == Example ==
%% ```
%% instrument_sampler:set_sampler(instrument_sampler_parent_based, #{
%%   root => instrument_sampler_probability,
%%   root_config => #{ratio => 0.1}
%% }).
%% '''
-module(instrument_sampler_parent_based).
-author("benoitc").

-include("instrument_otel.hrl").

-behaviour(instrument_sampler).

-export([
  should_sample/7,
  get_description/1
]).

%% @doc Samples based on parent context.
-spec should_sample(
  Config :: map(),
  TraceId :: binary(),
  SpanName :: binary(),
  SpanKind :: atom(),
  Attributes :: map(),
  Links :: list(),
  ParentCtx :: #span_ctx{} | undefined
) -> #sampling_result{}.
should_sample(Config, TraceId, SpanName, SpanKind, Attributes, Links, undefined) ->
  %% No parent - use root sampler
  RootSampler = maps:get(root, Config, instrument_sampler_always_on),
  RootConfig = maps:get(root_config, Config, #{}),
  RootSampler:should_sample(RootConfig, TraceId, SpanName, SpanKind, Attributes, Links, undefined);

should_sample(Config, TraceId, SpanName, SpanKind, Attributes, Links,
              #span_ctx{is_remote = true, trace_flags = Flags} = ParentCtx) ->
  %% Remote parent
  IsSampled = (Flags band 1) =:= 1,
  {Sampler, SamplerConfig} = case IsSampled of
    true ->
      {
        maps:get(remote_parent_sampled, Config, instrument_sampler_always_on),
        maps:get(remote_parent_sampled_config, Config, #{})
      };
    false ->
      {
        maps:get(remote_parent_not_sampled, Config, instrument_sampler_always_off),
        maps:get(remote_parent_not_sampled_config, Config, #{})
      }
  end,
  Sampler:should_sample(SamplerConfig, TraceId, SpanName, SpanKind, Attributes, Links, ParentCtx);

should_sample(Config, TraceId, SpanName, SpanKind, Attributes, Links,
              #span_ctx{is_remote = false, trace_flags = Flags} = ParentCtx) ->
  %% Local parent
  IsSampled = (Flags band 1) =:= 1,
  {Sampler, SamplerConfig} = case IsSampled of
    true ->
      {
        maps:get(local_parent_sampled, Config, instrument_sampler_always_on),
        maps:get(local_parent_sampled_config, Config, #{})
      };
    false ->
      {
        maps:get(local_parent_not_sampled, Config, instrument_sampler_always_off),
        maps:get(local_parent_not_sampled_config, Config, #{})
      }
  end,
  Sampler:should_sample(SamplerConfig, TraceId, SpanName, SpanKind, Attributes, Links, ParentCtx).

%% @doc Returns the sampler description.
-spec get_description(Config :: map()) -> binary().
get_description(Config) ->
  RootSampler = maps:get(root, Config, instrument_sampler_always_on),
  RootConfig = maps:get(root_config, Config, #{}),
  RootDesc = RootSampler:get_description(RootConfig),
  iolist_to_binary([<<"ParentBased{root=">>, RootDesc, <<"}">>]).
