%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_baggage_SUITE).
-author("benoitc").

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
  all/0,
  init_per_suite/1,
  end_per_suite/1,
  init_per_testcase/2,
  end_per_testcase/2
]).

-export([
  set_get_test/1,
  set_get_default_test/1,
  set_with_metadata_test/1,
  remove_test/1,
  get_all_test/1,
  clear_test/1,
  from_to_context_test/1,
  encode_simple_test/1,
  encode_multiple_test/1,
  decode_simple_test/1,
  decode_with_metadata_test/1,
  percent_encoding_test/1
]).

all() ->
  [
    set_get_test,
    set_get_default_test,
    set_with_metadata_test,
    remove_test,
    get_all_test,
    clear_test,
    from_to_context_test,
    encode_simple_test,
    encode_multiple_test,
    decode_simple_test,
    decode_with_metadata_test,
    percent_encoding_test
  ].

init_per_suite(Config) ->
  ok = application:start(instrument),
  Config.

end_per_suite(_Config) ->
  ok = application:stop(instrument),
  ok.

init_per_testcase(_TestCase, Config) ->
  %% Clear baggage before each test
  instrument_baggage:clear(),
  Config.

end_per_testcase(_TestCase, _Config) ->
  instrument_baggage:clear(),
  ok.

%% ============================================================================
%% Test Cases
%% ============================================================================

set_get_test(_Config) ->
  %% Set a value
  ok = instrument_baggage:set(<<"key1">>, <<"value1">>),

  %% Get the value
  Value = instrument_baggage:get(<<"key1">>),
  ?assertEqual(<<"value1">>, Value),
  ok.

set_get_default_test(_Config) ->
  %% Get with default when key doesn't exist
  Value = instrument_baggage:get(<<"nonexistent">>, <<"default">>),
  ?assertEqual(<<"default">>, Value),

  %% Get without default returns undefined
  Value2 = instrument_baggage:get(<<"nonexistent">>),
  ?assertEqual(undefined, Value2),
  ok.

set_with_metadata_test(_Config) ->
  %% Set with metadata
  Metadata = #{<<"property">> => <<"value">>},
  ok = instrument_baggage:set(<<"key1">>, <<"value1">>, Metadata),

  %% Get the value (metadata is stored but not returned by get/1)
  Value = instrument_baggage:get(<<"key1">>),
  ?assertEqual(<<"value1">>, Value),
  ok.

remove_test(_Config) ->
  %% Set and then remove
  ok = instrument_baggage:set(<<"key1">>, <<"value1">>),
  ?assertEqual(<<"value1">>, instrument_baggage:get(<<"key1">>)),

  ok = instrument_baggage:remove(<<"key1">>),
  ?assertEqual(undefined, instrument_baggage:get(<<"key1">>)),
  ok.

get_all_test(_Config) ->
  %% Set multiple values
  ok = instrument_baggage:set(<<"key1">>, <<"value1">>),
  ok = instrument_baggage:set(<<"key2">>, <<"value2">>),
  ok = instrument_baggage:set(<<"key3">>, <<"value3">>),

  %% Get all entries
  All = instrument_baggage:get_all(),
  ?assertEqual(3, maps:size(All)),
  ?assertEqual(<<"value1">>, maps:get(<<"key1">>, All)),
  ?assertEqual(<<"value2">>, maps:get(<<"key2">>, All)),
  ?assertEqual(<<"value3">>, maps:get(<<"key3">>, All)),
  ok.

clear_test(_Config) ->
  %% Set values
  ok = instrument_baggage:set(<<"key1">>, <<"value1">>),
  ok = instrument_baggage:set(<<"key2">>, <<"value2">>),

  %% Clear all
  ok = instrument_baggage:clear(),

  %% Verify empty
  All = instrument_baggage:get_all(),
  ?assertEqual(0, maps:size(All)),
  ok.

from_to_context_test(_Config) ->
  %% Create a baggage map
  Baggage = #{
    <<"key1">> => {<<"value1">>, #{}},
    <<"key2">> => {<<"value2">>, #{<<"meta">> => <<"data">>}}
  },

  %% Put into context
  Ctx = instrument_context:new(),
  CtxWithBaggage = instrument_baggage:to_context(Ctx, Baggage),

  %% Extract from context
  ExtractedBaggage = instrument_baggage:from_context(CtxWithBaggage),
  ?assertEqual(Baggage, ExtractedBaggage),
  ok.

encode_simple_test(_Config) ->
  %% Encode single entry
  Baggage = #{<<"key1">> => {<<"value1">>, #{}}},
  Encoded = instrument_baggage:encode(Baggage),
  ?assertEqual(<<"key1=value1">>, Encoded),
  ok.

encode_multiple_test(_Config) ->
  %% Encode multiple entries
  Baggage = #{
    <<"key1">> => {<<"value1">>, #{}},
    <<"key2">> => {<<"value2">>, #{}}
  },
  Encoded = instrument_baggage:encode(Baggage),

  %% Order may vary, so check both entries are present
  ?assert(binary:match(Encoded, <<"key1=value1">>) =/= nomatch),
  ?assert(binary:match(Encoded, <<"key2=value2">>) =/= nomatch),
  ?assert(binary:match(Encoded, <<",">>) =/= nomatch),
  ok.

decode_simple_test(_Config) ->
  %% Decode single entry
  Decoded = instrument_baggage:decode(<<"key1=value1">>),
  ?assertEqual({<<"value1">>, #{}}, maps:get(<<"key1">>, Decoded)),
  ok.

decode_with_metadata_test(_Config) ->
  %% Decode with metadata
  Decoded = instrument_baggage:decode(<<"key1=value1;property=meta">>),
  {Value, Metadata} = maps:get(<<"key1">>, Decoded),
  ?assertEqual(<<"value1">>, Value),
  ?assertEqual(<<"meta">>, maps:get(<<"property">>, Metadata)),
  ok.

percent_encoding_test(_Config) ->
  %% Test encoding special characters
  Baggage = #{<<"key">> => {<<"value with spaces">>, #{}}},
  Encoded = instrument_baggage:encode(Baggage),

  %% Space should be percent-encoded
  ?assert(binary:match(Encoded, <<"%20">>) =/= nomatch),

  %% Decode back
  Decoded = instrument_baggage:decode(Encoded),
  {Value, _} = maps:get(<<"key">>, Decoded),
  ?assertEqual(<<"value with spaces">>, Value),
  ok.
