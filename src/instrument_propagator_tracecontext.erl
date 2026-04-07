%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc W3C TraceContext propagator.
%%
%% This propagator handles the W3C TraceContext specification:
%% - traceparent: version-trace_id-span_id-flags
%% - tracestate: vendor-specific trace information
%%
%% See: https://www.w3.org/TR/trace-context/
-module(instrument_propagator_tracecontext).
-author("benoitc").

-behaviour(instrument_propagator).

-include("instrument_otel.hrl").

-export([
  inject/2,
  extract/2,
  fields/0
]).

-define(TRACEPARENT_HEADER, <<"traceparent">>).
-define(TRACESTATE_HEADER, <<"tracestate">>).

%% ============================================================================
%% Propagator Callbacks
%% ============================================================================

%% @doc Injects trace context into a carrier.
-spec inject(map(), map()) -> map().
inject(Ctx, Carrier) when is_map(Ctx), is_map(Carrier) ->
  Carrier1 = inject_traceparent(Ctx, Carrier),
  inject_tracestate(Ctx, Carrier1).

%% @doc Extracts trace context from a carrier.
-spec extract(map(), map()) -> map().
extract(Carrier, Ctx) when is_map(Carrier), is_map(Ctx) ->
  Ctx1 = extract_traceparent(Carrier, Ctx),
  extract_tracestate(Carrier, Ctx1).

%% @doc Returns the header fields used by this propagator.
-spec fields() -> [binary()].
fields() ->
  [?TRACEPARENT_HEADER, ?TRACESTATE_HEADER].

%% ============================================================================
%% Internal Functions
%% ============================================================================

inject_traceparent(Ctx, Carrier) ->
  case instrument_context:get_value(Ctx, span_ctx) of
    undefined -> Carrier;
    #span_ctx{trace_id = TraceId, span_id = SpanId, trace_flags = Flags} ->
      TraceIdHex = instrument_id:trace_id_to_hex(TraceId),
      SpanIdHex = instrument_id:span_id_to_hex(SpanId),
      FlagsHex = format_trace_flags(Flags),
      Value = <<"00-", TraceIdHex/binary, "-", SpanIdHex/binary, "-", FlagsHex/binary>>,
      maps:put(?TRACEPARENT_HEADER, Value, Carrier)
  end.

inject_tracestate(Ctx, Carrier) ->
  case instrument_context:get_value(Ctx, span_ctx) of
    undefined -> Carrier;
    #span_ctx{trace_state = []} -> Carrier;
    #span_ctx{trace_state = TraceState} ->
      Value = encode_tracestate(TraceState),
      maps:put(?TRACESTATE_HEADER, Value, Carrier)
  end.

extract_traceparent(Carrier, Ctx) ->
  case maps:get(?TRACEPARENT_HEADER, Carrier, undefined) of
    undefined -> Ctx;
    Value -> parse_traceparent(Value, Ctx)
  end.

extract_tracestate(Carrier, Ctx) ->
  case maps:get(?TRACESTATE_HEADER, Carrier, undefined) of
    undefined -> Ctx;
    Value ->
      case instrument_context:get_value(Ctx, span_ctx) of
        undefined -> Ctx;
        SpanCtx ->
          TraceState = decode_tracestate(Value),
          NewSpanCtx = SpanCtx#span_ctx{trace_state = TraceState},
          instrument_context:set_value(Ctx, span_ctx, NewSpanCtx)
      end
  end.

parse_traceparent(Value, Ctx) ->
  try
    %% Format: VERSION-TRACEID-SPANID-FLAGS
    %% Example: 00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01
    %% Per W3C spec: accept versions > 00 and try to parse known fields
    case binary:split(Value, <<"-">>, [global]) of
      [Version, TraceIdHex, SpanIdHex, FlagsHex | _Rest] when
          byte_size(Version) =:= 2,
          byte_size(TraceIdHex) =:= 32,
          byte_size(SpanIdHex) =:= 16,
          byte_size(FlagsHex) >= 2 ->
        %% Reject invalid version ff per W3C spec
        case Version of
          <<"ff">> -> Ctx;
          <<"FF">> -> Ctx;
          _ ->
            TraceId = instrument_id:hex_to_trace_id(TraceIdHex),
            SpanId = instrument_id:hex_to_span_id(SpanIdHex),
            %% Validate trace and span IDs (reject all-zero values per W3C spec)
            case instrument_id:is_valid_trace_id(TraceId) andalso
                 instrument_id:is_valid_span_id(SpanId) of
              true ->
                %% Only parse first 2 chars of flags for forward compat
                FlagsPart = binary:part(FlagsHex, 0, 2),
                Flags = parse_trace_flags(FlagsPart),
                SpanCtx = #span_ctx{
                  trace_id = TraceId,
                  span_id = SpanId,
                  trace_flags = Flags,
                  is_remote = true
                },
                instrument_context:set_value(Ctx, span_ctx, SpanCtx);
              false ->
                %% Invalid IDs, reject and return unchanged context
                Ctx
            end
        end;
      _ ->
        Ctx
    end
  catch
    Class:Reason:Stack ->
      logger:debug("Failed to parse traceparent ~p: ~p:~p~n~p",
                   [Value, Class, Reason, Stack]),
      Ctx
  end.

format_trace_flags(0) -> <<"00">>;
format_trace_flags(1) -> <<"01">>.

parse_trace_flags(<<"00">>) -> 0;
parse_trace_flags(<<"01">>) -> 1;
parse_trace_flags(Hex) ->
  binary_to_integer(Hex, 16) band 16#FF.

encode_tracestate(TraceState) ->
  Parts = [<<K/binary, "=", V/binary>> || {K, V} <- TraceState],
  iolist_to_binary(lists:join(<<",">>, Parts)).

decode_tracestate(Value) ->
  Parts = binary:split(Value, <<",">>, [global, trim_all]),
  lists:filtermap(fun(Part) ->
    case binary:split(Part, <<"=">>, [trim_all]) of
      [K, V] -> {true, {string:trim(K), string:trim(V)}};
      _ -> false
    end
  end, Parts).
