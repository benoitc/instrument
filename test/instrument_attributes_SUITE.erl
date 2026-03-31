%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_attributes_SUITE).
-author("benoitc").

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
  all/0,
  init_per_suite/1,
  end_per_suite/1
]).

-export([
  normalize_test/1,
  validate_test/1,
  hash_consistency_test/1,
  hash_different_test/1,
  to_label_values_test/1,
  merge_test/1,
  filter_test/1,
  empty_attrs_test/1
]).

all() ->
  [
    normalize_test,
    validate_test,
    hash_consistency_test,
    hash_different_test,
    to_label_values_test,
    merge_test,
    filter_test,
    empty_attrs_test
  ].

init_per_suite(Config) ->
  Config.

end_per_suite(_Config) ->
  ok.

%% ============================================================================
%% Test Cases
%% ============================================================================

normalize_test(_Config) ->
  %% Test normalizing various types

  %% From map with mixed key types
  Attrs = instrument_attributes:new(#{
    key1 => <<"value1">>,
    <<"key2">> => 42,
    key3 => true
  }),

  ?assertEqual(<<"value1">>, instrument_attributes:get(Attrs, key1)),
  ?assertEqual(42, instrument_attributes:get(Attrs, <<"key2">>)),
  ?assertEqual(true, instrument_attributes:get(Attrs, key3)),

  %% Atoms as values get converted to binary
  Attrs2 = instrument_attributes:new(#{key => my_atom}),
  ?assertEqual(<<"my_atom">>, instrument_attributes:get(Attrs2, key)),
  ok.

validate_test(_Config) ->
  %% Valid attributes
  {ok, _} = instrument_attributes:validate(#{
    key1 => <<"binary_value">>,
    key2 => 42,
    key3 => 3.14,
    key4 => true,
    key5 => [<<"a">>, <<"b">>, <<"c">>]
  }),

  %% Empty attributes are valid
  {ok, #{}} = instrument_attributes:validate(#{}),

  %% String key gets converted
  {ok, Attrs} = instrument_attributes:validate(#{"string_key" => <<"value">>}),
  ?assertEqual(<<"value">>, instrument_attributes:get(Attrs, <<"string_key">>)),
  ok.

hash_consistency_test(_Config) ->
  %% Same attributes (different order) should produce same hash
  Attrs1 = #{a => 1, b => 2, c => 3},
  Attrs2 = #{c => 3, a => 1, b => 2},
  Attrs3 = #{b => 2, c => 3, a => 1},

  Hash1 = instrument_attributes:hash(Attrs1),
  Hash2 = instrument_attributes:hash(Attrs2),
  Hash3 = instrument_attributes:hash(Attrs3),

  ?assertEqual(Hash1, Hash2),
  ?assertEqual(Hash2, Hash3),
  ok.

hash_different_test(_Config) ->
  %% Different attributes should produce different hashes
  Attrs1 = #{a => 1, b => 2},
  Attrs2 = #{a => 1, b => 3},
  Attrs3 = #{a => 1, c => 2},

  Hash1 = instrument_attributes:hash(Attrs1),
  Hash2 = instrument_attributes:hash(Attrs2),
  Hash3 = instrument_attributes:hash(Attrs3),

  ?assertNotEqual(Hash1, Hash2),
  ?assertNotEqual(Hash1, Hash3),
  ?assertNotEqual(Hash2, Hash3),
  ok.

to_label_values_test(_Config) ->
  %% Convert to label values in specific order
  Attrs = instrument_attributes:new(#{
    method => <<"GET">>,
    status => 200,
    path => <<"/api">>
  }),

  %% Get values in specific key order
  Values = instrument_attributes:to_label_values(Attrs, [method, status, path]),
  ?assertEqual([<<"GET">>, <<"200">>, <<"/api">>], Values),

  %% Different order
  Values2 = instrument_attributes:to_label_values(Attrs, [path, method]),
  ?assertEqual([<<"/api">>, <<"GET">>], Values2),

  %% Missing key returns empty binary
  Values3 = instrument_attributes:to_label_values(Attrs, [method, missing]),
  ?assertEqual([<<"GET">>, <<>>], Values3),
  ok.

merge_test(_Config) ->
  %% Merge two attribute sets
  Attrs1 = instrument_attributes:new(#{a => 1, b => 2}),
  Attrs2 = instrument_attributes:new(#{b => 3, c => 4}),

  Merged = instrument_attributes:merge(Attrs1, Attrs2),

  %% Second set overrides first
  ?assertEqual(1, instrument_attributes:get(Merged, a)),
  ?assertEqual(3, instrument_attributes:get(Merged, b)),
  ?assertEqual(4, instrument_attributes:get(Merged, c)),
  ok.

filter_test(_Config) ->
  %% Test remove functionality (filtering by removing keys)
  Attrs = instrument_attributes:new(#{a => 1, b => 2, c => 3}),

  %% Remove a key
  Filtered = instrument_attributes:remove(Attrs, b),

  ?assertEqual(1, instrument_attributes:get(Filtered, a)),
  ?assertEqual(undefined, instrument_attributes:get(Filtered, b)),
  ?assertEqual(3, instrument_attributes:get(Filtered, c)),
  ok.

empty_attrs_test(_Config) ->
  %% Empty attribute handling
  Empty = instrument_attributes:new(),
  ?assertEqual(#{}, Empty),

  %% Get from empty returns undefined
  ?assertEqual(undefined, instrument_attributes:get(Empty, key)),

  %% Get with default from empty
  ?assertEqual(<<"default">>, instrument_attributes:get(Empty, key, <<"default">>)),

  %% Hash of empty
  Hash = instrument_attributes:hash(#{}),
  ?assert(is_integer(Hash)),

  %% To list of empty
  ?assertEqual([], instrument_attributes:to_list(Empty)),

  %% Merge with empty
  Attrs = instrument_attributes:new(#{a => 1}),
  Merged = instrument_attributes:merge(Empty, Attrs),
  ?assertEqual(1, instrument_attributes:get(Merged, a)),
  ok.
