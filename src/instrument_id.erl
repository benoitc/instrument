%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Trace and Span ID generation per W3C TraceContext spec.
%%
%% Provides cryptographically random ID generation and hex encoding/decoding.
-module(instrument_id).
-author("benoitc").

-export([
  generate_trace_id/0,
  generate_span_id/0,
  trace_id_to_hex/1,
  span_id_to_hex/1,
  hex_to_trace_id/1,
  hex_to_span_id/1,
  is_valid_trace_id/1,
  is_valid_span_id/1
]).

%% W3C TraceContext sizes
-define(TRACE_ID_BYTES, 16).  %% 128 bits
-define(SPAN_ID_BYTES, 8).    %% 64 bits

-type trace_id() :: <<_:128>>.
-type span_id() :: <<_:64>>.

-export_type([trace_id/0, span_id/0]).

%% @doc Generates a random 128-bit trace ID.
%% The ID is guaranteed to be non-zero per W3C spec.
-spec generate_trace_id() -> trace_id().
generate_trace_id() ->
  generate_non_zero(?TRACE_ID_BYTES).

%% @doc Generates a random 64-bit span ID.
%% The ID is guaranteed to be non-zero per W3C spec.
-spec generate_span_id() -> span_id().
generate_span_id() ->
  generate_non_zero(?SPAN_ID_BYTES).

%% @doc Converts a trace ID to lowercase hex string.
-spec trace_id_to_hex(trace_id()) -> binary().
trace_id_to_hex(TraceId) when is_binary(TraceId), byte_size(TraceId) =:= ?TRACE_ID_BYTES ->
  to_hex(TraceId);
trace_id_to_hex(undefined) ->
  <<"00000000000000000000000000000000">>.

%% @doc Converts a span ID to lowercase hex string.
-spec span_id_to_hex(span_id()) -> binary().
span_id_to_hex(SpanId) when is_binary(SpanId), byte_size(SpanId) =:= ?SPAN_ID_BYTES ->
  to_hex(SpanId);
span_id_to_hex(undefined) ->
  <<"0000000000000000">>.

%% @doc Converts a hex string to a trace ID.
-spec hex_to_trace_id(binary()) -> trace_id().
hex_to_trace_id(Hex) when is_binary(Hex), byte_size(Hex) =:= 32 ->
  from_hex(Hex).

%% @doc Converts a hex string to a span ID.
-spec hex_to_span_id(binary()) -> span_id().
hex_to_span_id(Hex) when is_binary(Hex), byte_size(Hex) =:= 16 ->
  from_hex(Hex).

%% @doc Checks if a trace ID is valid (non-zero).
-spec is_valid_trace_id(trace_id() | undefined) -> boolean().
is_valid_trace_id(undefined) -> false;
is_valid_trace_id(TraceId) when is_binary(TraceId), byte_size(TraceId) =:= ?TRACE_ID_BYTES ->
  TraceId =/= <<0:128>>;
is_valid_trace_id(_) -> false.

%% @doc Checks if a span ID is valid (non-zero).
-spec is_valid_span_id(span_id() | undefined) -> boolean().
is_valid_span_id(undefined) -> false;
is_valid_span_id(SpanId) when is_binary(SpanId), byte_size(SpanId) =:= ?SPAN_ID_BYTES ->
  SpanId =/= <<0:64>>;
is_valid_span_id(_) -> false.

%% Internal functions

%% Generate a non-zero random binary of given size
generate_non_zero(Size) ->
  Id = crypto:strong_rand_bytes(Size),
  case is_all_zeros(Id) of
    true -> generate_non_zero(Size);
    false -> Id
  end.

%% Check if all bytes are zero
is_all_zeros(<<>>) -> true;
is_all_zeros(<<0, Rest/binary>>) -> is_all_zeros(Rest);
is_all_zeros(_) -> false.

%% Convert binary to lowercase hex
to_hex(Bin) ->
  << <<(hex_digit(N div 16)), (hex_digit(N rem 16))>> || <<N>> <= Bin >>.

hex_digit(N) when N < 10 -> $0 + N;
hex_digit(N) -> $a + N - 10.

%% Convert hex to binary
from_hex(Hex) ->
  << <<(hex_to_int(H, L))>> || <<H, L>> <= Hex >>.

hex_to_int(H, L) ->
  (hex_char_val(H) bsl 4) bor hex_char_val(L).

hex_char_val(C) when C >= $0, C =< $9 -> C - $0;
hex_char_val(C) when C >= $a, C =< $f -> C - $a + 10;
hex_char_val(C) when C >= $A, C =< $F -> C - $A + 10.
