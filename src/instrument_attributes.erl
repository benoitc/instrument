%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Attribute handling for OpenTelemetry-compatible instrumentation.
%%
%% Attributes are key-value pairs used for dimensions in metrics and
%% metadata in traces. Keys must be atoms or binaries, values can be
%% binaries, integers, floats, or booleans.
-module(instrument_attributes).
-author("benoitc").

-export([
  new/0,
  new/1,
  put/3,
  get/2,
  get/3,
  merge/2,
  remove/2,
  to_list/1,
  from_list/1,
  validate/1,
  to_label_values/2,
  hash/1
]).

-type attribute_key() :: atom() | binary().
-type attribute_value() :: binary() | integer() | float() | boolean() |
                          [binary()] | [integer()] | [float()] | [boolean()].
-type t() :: #{attribute_key() => attribute_value()}.

-export_type([t/0, attribute_key/0, attribute_value/0]).

%% @doc Creates a new empty attribute set.
-spec new() -> t().
new() ->
  #{}.

%% @doc Creates an attribute set from a map or proplist.
-spec new(map() | [{term(), term()}]) -> t().
new(Map) when is_map(Map) ->
  maps:fold(fun(K, V, Acc) ->
    case validate_pair(K, V) of
      {ok, NormK, NormV} -> maps:put(NormK, NormV, Acc);
      error -> Acc
    end
  end, #{}, Map);
new(List) when is_list(List) ->
  new(maps:from_list(List)).

%% @doc Puts a key-value pair into the attributes.
-spec put(t(), attribute_key(), attribute_value()) -> t().
put(Attrs, Key, Value) when is_map(Attrs) ->
  case validate_pair(Key, Value) of
    {ok, NormK, NormV} -> maps:put(NormK, NormV, Attrs);
    error -> Attrs
  end.

%% @doc Gets a value from the attributes.
-spec get(t(), attribute_key()) -> attribute_value() | undefined.
get(Attrs, Key) ->
  get(Attrs, Key, undefined).

%% @doc Gets a value from the attributes with a default.
-spec get(t(), attribute_key(), term()) -> attribute_value() | term().
get(Attrs, Key, Default) when is_map(Attrs) ->
  NormK = normalize_key(Key),
  maps:get(NormK, Attrs, Default).

%% @doc Merges two attribute sets. Values in the second set override the first.
-spec merge(t(), t()) -> t().
merge(Attrs1, Attrs2) when is_map(Attrs1), is_map(Attrs2) ->
  maps:merge(Attrs1, Attrs2).

%% @doc Removes a key from the attributes.
-spec remove(t(), attribute_key()) -> t().
remove(Attrs, Key) when is_map(Attrs) ->
  NormK = normalize_key(Key),
  maps:remove(NormK, Attrs).

%% @doc Converts attributes to a list of {key, value} pairs.
-spec to_list(t()) -> [{attribute_key(), attribute_value()}].
to_list(Attrs) when is_map(Attrs) ->
  maps:to_list(Attrs).

%% @doc Creates attributes from a list of {key, value} pairs.
-spec from_list([{term(), term()}]) -> t().
from_list(List) when is_list(List) ->
  new(List).

%% @doc Validates all attributes in the set.
%% Returns {ok, Attrs} if valid, {error, Reason} if not.
-spec validate(t()) -> {ok, t()} | {error, term()}.
validate(Attrs) when is_map(Attrs) ->
  try
    Validated = maps:fold(fun(K, V, Acc) ->
      case validate_pair(K, V) of
        {ok, NormK, NormV} -> maps:put(NormK, NormV, Acc);
        error -> throw({invalid_attribute, K, V})
      end
    end, #{}, Attrs),
    {ok, Validated}
  catch
    throw:Reason -> {error, Reason}
  end.

%% @doc Extracts label values in order matching the given label keys.
%% This is used for compatibility with the existing vector metrics.
-spec to_label_values(t(), [attribute_key()]) -> [binary()].
to_label_values(Attrs, Keys) when is_map(Attrs), is_list(Keys) ->
  [value_to_binary(get(Attrs, K, <<>>)) || K <- Keys].

%% @doc Computes a hash of the attributes for use as map keys.
-spec hash(t()) -> integer().
hash(Attrs) when is_map(Attrs) ->
  %% Sort keys for consistent hashing
  Sorted = lists:sort(maps:to_list(Attrs)),
  erlang:phash2(Sorted).

%% Internal functions

normalize_key(Key) when is_atom(Key) -> Key;
normalize_key(Key) when is_binary(Key) -> Key;
normalize_key(Key) when is_list(Key) -> list_to_binary(Key).

validate_pair(Key, Value) ->
  case validate_key(Key) of
    {ok, NormK} ->
      case validate_value(Value) of
        {ok, NormV} -> {ok, NormK, NormV};
        error -> error
      end;
    error -> error
  end.

validate_key(Key) when is_atom(Key) -> {ok, Key};
validate_key(Key) when is_binary(Key), byte_size(Key) > 0 -> {ok, Key};
validate_key(Key) when is_list(Key), length(Key) > 0 -> {ok, list_to_binary(Key)};
validate_key(_) -> error.

validate_value(V) when is_binary(V) -> {ok, V};
validate_value(V) when is_integer(V) -> {ok, V};
validate_value(V) when is_float(V) -> {ok, V};
validate_value(V) when is_boolean(V) -> {ok, V};
validate_value(V) when is_atom(V) -> {ok, atom_to_binary(V, utf8)};
validate_value(V) when is_list(V) ->
  case validate_list_value(V) of
    {ok, List} -> {ok, List};
    _ ->
      %% Try to convert to binary if it's a string
      try
        {ok, list_to_binary(V)}
      catch
        _:_ -> error
      end
  end;
validate_value(_) -> error.

validate_list_value([]) -> {ok, []};
validate_list_value([H | T]) when is_binary(H) ->
  case validate_list_value(T) of
    {ok, Rest} -> {ok, [H | Rest]};
    error -> error
  end;
validate_list_value([H | T]) when is_integer(H) ->
  case validate_list_value(T) of
    {ok, Rest} -> {ok, [H | Rest]};
    error -> error
  end;
validate_list_value([H | T]) when is_float(H) ->
  case validate_list_value(T) of
    {ok, Rest} -> {ok, [H | Rest]};
    error -> error
  end;
validate_list_value([H | T]) when is_boolean(H) ->
  case validate_list_value(T) of
    {ok, Rest} -> {ok, [H | Rest]};
    error -> error
  end;
validate_list_value(_) -> error.

value_to_binary(V) when is_binary(V) -> V;
value_to_binary(V) when is_atom(V) -> atom_to_binary(V, utf8);
value_to_binary(V) when is_integer(V) -> integer_to_binary(V);
value_to_binary(V) when is_float(V) -> float_to_binary(V, [{decimals, 10}, compact]);
value_to_binary(true) -> <<"true">>;
value_to_binary(false) -> <<"false">>;
value_to_binary(V) when is_list(V) ->
  case io_lib:printable_unicode_list(V) of
    true -> list_to_binary(V);
    false -> iolist_to_binary(io_lib:format("~p", [V]))
  end.
