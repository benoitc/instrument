%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Baggage propagation for OpenTelemetry-compatible instrumentation.
%%
%% Baggage is used to propagate key-value pairs across service boundaries.
%% It is stored as part of the context and can be encoded/decoded using
%% W3C Baggage format.
-module(instrument_baggage).
-author("benoitc").

-export([
  get/1,
  get/2,
  set/2,
  set/3,
  remove/1,
  get_all/0,
  clear/0,
  from_context/1,
  to_context/2
]).

%% W3C Baggage format
-export([
  encode/1,
  decode/1
]).

-define(BAGGAGE_KEY, '$instrument_baggage').

-type baggage_key() :: binary() | atom() | string().
-type baggage_value() :: binary() | atom() | string() | number().
-type metadata() :: #{binary() => binary()}.
-type baggage_entry() :: {baggage_value(), metadata()}.
-type baggage() :: #{baggage_key() => baggage_entry()}.

-export_type([baggage/0, baggage_key/0, baggage_value/0]).

%% @doc Gets a value from the current baggage.
-spec get(baggage_key()) -> baggage_value() | undefined.
get(Key) ->
  get(Key, undefined).

%% @doc Gets a value from the current baggage with a default.
-spec get(baggage_key(), term()) -> baggage_value() | term().
get(Key, Default) ->
  Ctx = instrument_context:current(),
  Baggage = from_context(Ctx),
  NormalizedKey = normalize_key(Key),
  case maps:get(NormalizedKey, Baggage, undefined) of
    undefined -> Default;
    {Value, _Metadata} -> Value
  end.

%% @doc Sets a value in the current baggage (no metadata).
-spec set(baggage_key(), baggage_value()) -> ok.
set(Key, Value) ->
  set(Key, Value, #{}).

%% @doc Sets a value in the current baggage with metadata.
-spec set(baggage_key(), baggage_value(), metadata()) -> ok.
set(Key, Value, Metadata) when is_map(Metadata) ->
  Ctx = instrument_context:current(),
  Baggage = from_context(Ctx),
  NormalizedKey = normalize_key(Key),
  NewBaggage = maps:put(NormalizedKey, {Value, Metadata}, Baggage),
  NewCtx = to_context(Ctx, NewBaggage),
  instrument_context:set_current(NewCtx).

%% @doc Removes a key from the current baggage.
-spec remove(baggage_key()) -> ok.
remove(Key) ->
  Ctx = instrument_context:current(),
  Baggage = from_context(Ctx),
  NormalizedKey = normalize_key(Key),
  NewBaggage = maps:remove(NormalizedKey, Baggage),
  NewCtx = to_context(Ctx, NewBaggage),
  instrument_context:set_current(NewCtx).

%% @doc Gets all baggage entries.
-spec get_all() -> #{baggage_key() => baggage_value()}.
get_all() ->
  Ctx = instrument_context:current(),
  Baggage = from_context(Ctx),
  maps:map(fun(_K, {V, _M}) -> V end, Baggage).

%% @doc Clears all baggage.
-spec clear() -> ok.
clear() ->
  Ctx = instrument_context:current(),
  NewCtx = to_context(Ctx, #{}),
  instrument_context:set_current(NewCtx).

%% @doc Extracts baggage from a context.
-spec from_context(instrument_context:context()) -> baggage().
from_context(Ctx) ->
  instrument_context:get_value(Ctx, ?BAGGAGE_KEY, #{}).

%% @doc Puts baggage into a context.
-spec to_context(instrument_context:context(), baggage()) -> instrument_context:context().
to_context(Ctx, Baggage) when is_map(Baggage) ->
  instrument_context:set_value(Ctx, ?BAGGAGE_KEY, Baggage).

%% W3C Baggage format encoding/decoding

%% @doc Encodes baggage to W3C Baggage header format.
%% Format: key1=value1;metadata1,key2=value2
-spec encode(baggage()) -> binary().
encode(Baggage) when is_map(Baggage) ->
  Entries = maps:fold(fun(Key, {Value, Metadata}, Acc) ->
    Entry = encode_entry(Key, Value, Metadata),
    [Entry | Acc]
  end, [], Baggage),
  iolist_to_binary(lists:join(<<",">>, Entries)).

%% @doc Decodes W3C Baggage header format to baggage.
-spec decode(binary() | string()) -> baggage().
decode(Header) when is_list(Header) ->
  decode(list_to_binary(Header));
decode(Header) when is_binary(Header) ->
  case Header of
    <<>> -> #{};
    _ ->
      Entries = binary:split(Header, <<",">>, [global, trim_all]),
      lists:foldl(fun decode_entry/2, #{}, Entries)
  end.

%% Internal functions

normalize_key(Key) when is_atom(Key) -> atom_to_binary(Key, utf8);
normalize_key(Key) when is_list(Key) -> list_to_binary(Key);
normalize_key(Key) when is_binary(Key) -> Key.

encode_entry(Key, Value, Metadata) ->
  KeyBin = encode_key(Key),
  ValueBin = encode_value(Value),
  MetaBin = encode_metadata(Metadata),
  case MetaBin of
    <<>> -> <<KeyBin/binary, "=", ValueBin/binary>>;
    _ -> <<KeyBin/binary, "=", ValueBin/binary, ";", MetaBin/binary>>
  end.

encode_key(Key) when is_atom(Key) -> atom_to_binary(Key, utf8);
encode_key(Key) when is_list(Key) -> list_to_binary(Key);
encode_key(Key) when is_binary(Key) -> Key.

encode_value(Value) when is_atom(Value) ->
  percent_encode(atom_to_binary(Value, utf8));
encode_value(Value) when is_list(Value) ->
  percent_encode(list_to_binary(Value));
encode_value(Value) when is_binary(Value) ->
  percent_encode(Value);
encode_value(Value) when is_integer(Value) ->
  integer_to_binary(Value);
encode_value(Value) when is_float(Value) ->
  float_to_binary(Value, [{decimals, 10}, compact]).

encode_metadata(Metadata) when map_size(Metadata) =:= 0 -> <<>>;
encode_metadata(Metadata) ->
  Parts = maps:fold(fun(K, V, Acc) ->
    [[K, <<"=">>, V] | Acc]
  end, [], Metadata),
  iolist_to_binary(lists:join(<<";">>, Parts)).

decode_entry(Entry, Acc) ->
  case binary:split(Entry, <<"=">>, [trim_all]) of
    [Key, Rest] ->
      {Value, Metadata} = decode_value_and_metadata(Rest),
      maps:put(string:trim(Key), {Value, Metadata}, Acc);
    _ ->
      Acc
  end.

decode_value_and_metadata(Rest) ->
  case binary:split(Rest, <<";">>, [trim_all]) of
    [Value] ->
      {percent_decode(string:trim(Value)), #{}};
    [Value | MetaParts] ->
      Metadata = lists:foldl(fun decode_metadata_part/2, #{}, MetaParts),
      {percent_decode(string:trim(Value)), Metadata}
  end.

decode_metadata_part(Part, Acc) ->
  case binary:split(Part, <<"=">>, [trim_all]) of
    [Key, Value] ->
      maps:put(string:trim(Key), string:trim(Value), Acc);
    _ ->
      Acc
  end.

%% Simple percent encoding for baggage values
percent_encode(Bin) ->
  << <<(percent_encode_char(C))/binary>> || <<C>> <= Bin >>.

percent_encode_char(C) when C >= $a, C =< $z -> <<C>>;
percent_encode_char(C) when C >= $A, C =< $Z -> <<C>>;
percent_encode_char(C) when C >= $0, C =< $9 -> <<C>>;
percent_encode_char(C) when C =:= $-; C =:= $_; C =:= $.; C =:= $~ -> <<C>>;
percent_encode_char(C) ->
  <<$%, (hex_char(C bsr 4)), (hex_char(C band 16#0F))>>.

hex_char(N) when N < 10 -> $0 + N;
hex_char(N) -> $A + N - 10.

percent_decode(Bin) ->
  percent_decode(Bin, <<>>).

percent_decode(<<>>, Acc) -> Acc;
percent_decode(<<$%, H1, H2, Rest/binary>>, Acc) ->
  C = (hex_val(H1) bsl 4) bor hex_val(H2),
  percent_decode(Rest, <<Acc/binary, C>>);
percent_decode(<<C, Rest/binary>>, Acc) ->
  percent_decode(Rest, <<Acc/binary, C>>).

hex_val(C) when C >= $0, C =< $9 -> C - $0;
hex_val(C) when C >= $A, C =< $F -> C - $A + 10;
hex_val(C) when C >= $a, C =< $f -> C - $a + 10.
