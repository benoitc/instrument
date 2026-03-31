%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc B3 Multi-Header propagator.
%%
%% Implements the B3 multi-header format per openzipkin/b3-propagation:
%% - X-B3-TraceId: 32 or 16 hex chars
%% - X-B3-SpanId: 16 hex chars
%% - X-B3-ParentSpanId: 16 hex chars (optional)
%% - X-B3-Sampled: 0 or 1 (optional)
%% - X-B3-Flags: 1 for debug (optional, implies sampled)
%%
%% See: https://github.com/openzipkin/b3-propagation
-module(instrument_propagator_b3_multi).
-author("benoitc").

-behaviour(instrument_propagator).

-include("instrument_otel.hrl").

-export([
  inject/2,
  extract/2,
  fields/0
]).

-define(TRACEID_HEADER, <<"x-b3-traceid">>).
-define(SPANID_HEADER, <<"x-b3-spanid">>).
-define(PARENTSPANID_HEADER, <<"x-b3-parentspanid">>).
-define(SAMPLED_HEADER, <<"x-b3-sampled">>).
-define(FLAGS_HEADER, <<"x-b3-flags">>).

%% ============================================================================
%% Propagator Callbacks
%% ============================================================================

%% @doc Injects trace context into a carrier using B3 multi-header format.
-spec inject(map(), map()) -> map().
inject(Ctx, Carrier) when is_map(Ctx), is_map(Carrier) ->
  case instrument_context:get_value(Ctx, span_ctx) of
    undefined ->
      Carrier;
    #span_ctx{trace_id = TraceId, span_id = SpanId, trace_flags = Flags} ->
      TraceIdHex = instrument_id:trace_id_to_hex(TraceId),
      SpanIdHex = instrument_id:span_id_to_hex(SpanId),
      SampledValue = format_sampled(Flags),
      Carrier1 = maps:put(?TRACEID_HEADER, TraceIdHex, Carrier),
      Carrier2 = maps:put(?SPANID_HEADER, SpanIdHex, Carrier1),
      maps:put(?SAMPLED_HEADER, SampledValue, Carrier2)
  end.

%% @doc Extracts trace context from a carrier using B3 multi-header format.
-spec extract(map(), map()) -> map().
extract(Carrier, Ctx) when is_map(Carrier), is_map(Ctx) ->
  try
    case get_header(Carrier, ?TRACEID_HEADER) of
      undefined ->
        Ctx;
      TraceIdHex ->
        case get_header(Carrier, ?SPANID_HEADER) of
          undefined ->
            Ctx;
          SpanIdHex ->
            create_span_ctx(TraceIdHex, SpanIdHex, Carrier, Ctx)
        end
    end
  catch
    _:_ -> Ctx
  end.

%% @doc Returns the header fields used by this propagator.
-spec fields() -> [binary()].
fields() ->
  [?TRACEID_HEADER, ?SPANID_HEADER, ?PARENTSPANID_HEADER, ?SAMPLED_HEADER, ?FLAGS_HEADER].

%% ============================================================================
%% Internal Functions
%% ============================================================================

%% Get header value (case-insensitive lookup)
get_header(Carrier, Header) ->
  case maps:get(Header, Carrier, undefined) of
    undefined ->
      %% Try lowercase key
      LowerHeader = string:lowercase(Header),
      maps:get(LowerHeader, Carrier, undefined);
    Value ->
      Value
  end.

create_span_ctx(TraceIdHex, SpanIdHex, Carrier, Ctx) ->
  %% Handle 64-bit (16 char) trace IDs by zero-padding
  TraceIdHex32 = pad_trace_id(TraceIdHex),
  case byte_size(TraceIdHex32) =:= 32 andalso byte_size(SpanIdHex) =:= 16 of
    true ->
      TraceId = instrument_id:hex_to_trace_id(TraceIdHex32),
      SpanId = instrument_id:hex_to_span_id(SpanIdHex),
      case instrument_id:is_valid_trace_id(TraceId) andalso
           instrument_id:is_valid_span_id(SpanId) of
        true ->
          Flags = parse_sampling(Carrier),
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

%% Parse sampling from headers
%% X-B3-Flags: 1 implies debug (sampled)
%% X-B3-Sampled: 0 or 1
parse_sampling(Carrier) ->
  case get_header(Carrier, ?FLAGS_HEADER) of
    <<"1">> ->
      %% Debug flag implies sampled
      1;
    _ ->
      case get_header(Carrier, ?SAMPLED_HEADER) of
        <<"0">> -> 0;
        <<"1">> -> 1;
        <<"true">> -> 1;
        <<"false">> -> 0;
        _ -> 1  %% Default to sampled
      end
  end.

%% Format trace_flags to X-B3-Sampled value
format_sampled(0) -> <<"0">>;
format_sampled(1) -> <<"1">>.
