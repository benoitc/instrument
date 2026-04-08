%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc B3 Single-Header propagator.
%%
%% Implements the B3 single-header format per openzipkin/b3-propagation:
%% Format: `{TraceId}-{SpanId}-{SamplingState}-{ParentSpanId}'
%%
%% See: https://github.com/openzipkin/b3-propagation
-module(instrument_propagator_b3).
-author("benoitc").

-behaviour(instrument_propagator).

-include("instrument_otel.hrl").

-export([
  inject/2,
  extract/2,
  fields/0
]).

-define(B3_HEADER, <<"b3">>).

%% ============================================================================
%% Propagator Callbacks
%% ============================================================================

%% @doc Injects trace context into a carrier using B3 single header format.
%% Format: {TraceId}-{SpanId}-{SamplingState}[-{ParentSpanId}]
-spec inject(map(), map()) -> map().
inject(Ctx, Carrier) when is_map(Ctx), is_map(Carrier) ->
  case instrument_context:get_value(Ctx, span_ctx) of
    undefined ->
      Carrier;
    #span_ctx{trace_id = TraceId, span_id = SpanId, trace_flags = Flags} ->
      TraceIdHex = instrument_id:trace_id_to_hex(TraceId),
      SpanIdHex = instrument_id:span_id_to_hex(SpanId),
      SamplingState = format_sampling_state(Flags),
      %% Try to get parent span ID from the full span record
      ParentSpanIdPart = case get_parent_span_id(Ctx) of
        undefined -> <<>>;
        ParentSpanIdHex -> <<"-", ParentSpanIdHex/binary>>
      end,
      %% Format: {TraceId}-{SpanId}-{SamplingState}[-{ParentSpanId}]
      Value = <<TraceIdHex/binary, "-", SpanIdHex/binary, "-", SamplingState/binary, ParentSpanIdPart/binary>>,
      maps:put(?B3_HEADER, Value, Carrier)
  end.

%% @doc Extracts trace context from a carrier using B3 single header format.
-spec extract(map(), map()) -> map().
extract(Carrier, Ctx) when is_map(Carrier), is_map(Ctx) ->
  case get_header(Carrier, ?B3_HEADER) of
    undefined ->
      Ctx;
    Value ->
      parse_b3_header(Value, Ctx)
  end.

%% @doc Returns the header fields used by this propagator.
-spec fields() -> [binary()].
fields() ->
  [?B3_HEADER].

%% ============================================================================
%% Internal Functions
%% ============================================================================

%% Get header value (case-insensitive lookup)
get_header(Carrier, Header) ->
  case maps:get(Header, Carrier, undefined) of
    undefined ->
      %% Try lowercase key
      maps:get(string:lowercase(Header), Carrier, undefined);
    Value ->
      Value
  end.

%% Parse B3 single header
%% Formats:
%% - {TraceId}-{SpanId}-{SamplingState}-{ParentSpanId}
%% - {TraceId}-{SpanId}-{SamplingState}
%% - {TraceId}-{SpanId}
%% - {SamplingState} (sampling-only: "0" or "1")
parse_b3_header(Value, Ctx) ->
  try
    case Value of
      <<"0">> ->
        %% Sampling-only deny - no trace context
        Ctx;
      <<"1">> ->
        %% Sampling-only accept - no trace context
        Ctx;
      _ ->
        parse_full_b3_header(Value, Ctx)
    end
  catch
    _:_ -> Ctx
  end.

parse_full_b3_header(Value, Ctx) ->
  case binary:split(Value, <<"-">>, [global]) of
    [TraceIdHex, SpanIdHex] ->
      %% No sampling state - default to sampled
      create_span_ctx(TraceIdHex, SpanIdHex, undefined, Ctx);
    [TraceIdHex, SpanIdHex, SamplingState] ->
      create_span_ctx(TraceIdHex, SpanIdHex, SamplingState, Ctx);
    [TraceIdHex, SpanIdHex, SamplingState, _ParentSpanId] ->
      %% ParentSpanId is ignored for context extraction
      create_span_ctx(TraceIdHex, SpanIdHex, SamplingState, Ctx);
    _ ->
      Ctx
  end.

create_span_ctx(TraceIdHex, SpanIdHex, SamplingState, Ctx) ->
  %% Handle 64-bit (16 char) trace IDs by zero-padding
  TraceIdHex32 = pad_trace_id(TraceIdHex),
  case byte_size(TraceIdHex32) =:= 32 andalso byte_size(SpanIdHex) =:= 16 of
    true ->
      TraceId = instrument_id:hex_to_trace_id(TraceIdHex32),
      SpanId = instrument_id:hex_to_span_id(SpanIdHex),
      case instrument_id:is_valid_trace_id(TraceId) andalso
           instrument_id:is_valid_span_id(SpanId) of
        true ->
          Flags = parse_sampling_state(SamplingState),
          SpanCtx = #span_ctx{
            trace_id = TraceId,
            span_id = SpanId,
            trace_flags = Flags,
            is_remote = true
          },
          instrument_context:set_value(Ctx, span_ctx, SpanCtx);
        false ->
          Ctx
      end;
    false ->
      Ctx
  end.

%% Pad 64-bit (16 char) trace ID to 128-bit (32 char) with leading zeros
pad_trace_id(TraceIdHex) when byte_size(TraceIdHex) =:= 16 ->
  <<"0000000000000000", TraceIdHex/binary>>;
pad_trace_id(TraceIdHex) when byte_size(TraceIdHex) =:= 32 ->
  TraceIdHex;
pad_trace_id(_) ->
  %% Invalid size
  <<>>.

%% Parse B3 sampling state to OTel trace_flags
parse_sampling_state(undefined) -> 1;  %% Default to sampled
parse_sampling_state(<<"0">>) -> 0;     %% Deny
parse_sampling_state(<<"1">>) -> 1;     %% Accept
parse_sampling_state(<<"d">>) -> 1;     %% Debug (implies sampled)
parse_sampling_state(<<"D">>) -> 1;     %% Debug (case-insensitive)
parse_sampling_state(_) -> 1.           %% Default to sampled

%% Format OTel trace_flags to B3 sampling state
format_sampling_state(0) -> <<"0">>;
format_sampling_state(1) -> <<"1">>.

%% Get parent span ID from the full span record in context
get_parent_span_id(Ctx) ->
  %% The full span is stored under '$instrument_span' key
  case instrument_context:get_value(Ctx, '$instrument_span') of
    #span{parent_ctx = #span_ctx{span_id = ParentSpanId}} when ParentSpanId =/= undefined ->
      instrument_id:span_id_to_hex(ParentSpanId);
    _ ->
      undefined
  end.
