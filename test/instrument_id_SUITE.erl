%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_id_SUITE).
-author("benoitc").

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
  all/0,
  init_per_suite/1,
  end_per_suite/1
]).

-export([
  generate_trace_id_test/1,
  generate_span_id_test/1,
  trace_id_uniqueness_test/1,
  span_id_uniqueness_test/1,
  trace_id_hex_roundtrip_test/1,
  span_id_hex_roundtrip_test/1,
  trace_id_undefined_hex_test/1,
  span_id_undefined_hex_test/1,
  is_valid_trace_id_test/1,
  is_valid_span_id_test/1
]).

all() ->
  [
    generate_trace_id_test,
    generate_span_id_test,
    trace_id_uniqueness_test,
    span_id_uniqueness_test,
    trace_id_hex_roundtrip_test,
    span_id_hex_roundtrip_test,
    trace_id_undefined_hex_test,
    span_id_undefined_hex_test,
    is_valid_trace_id_test,
    is_valid_span_id_test
  ].

init_per_suite(Config) ->
  _ = application:ensure_all_started(crypto),
  Config.

end_per_suite(_Config) ->
  ok.

%% ============================================================================
%% Test Cases
%% ============================================================================

generate_trace_id_test(_Config) ->
  TraceId = instrument_id:generate_trace_id(),
  %% Verify 16 bytes (128 bits)
  ?assertEqual(16, byte_size(TraceId)),
  %% Verify non-zero
  ?assertNotEqual(<<0:128>>, TraceId),
  ok.

generate_span_id_test(_Config) ->
  SpanId = instrument_id:generate_span_id(),
  %% Verify 8 bytes (64 bits)
  ?assertEqual(8, byte_size(SpanId)),
  %% Verify non-zero
  ?assertNotEqual(<<0:64>>, SpanId),
  ok.

trace_id_uniqueness_test(_Config) ->
  %% Generate 1000 IDs and verify all unique
  Ids = [instrument_id:generate_trace_id() || _ <- lists:seq(1, 1000)],
  UniqueIds = lists:usort(Ids),
  ?assertEqual(1000, length(UniqueIds)),
  ok.

span_id_uniqueness_test(_Config) ->
  %% Generate 1000 IDs and verify all unique
  Ids = [instrument_id:generate_span_id() || _ <- lists:seq(1, 1000)],
  UniqueIds = lists:usort(Ids),
  ?assertEqual(1000, length(UniqueIds)),
  ok.

trace_id_hex_roundtrip_test(_Config) ->
  %% Generate, encode, decode, verify match
  TraceId = instrument_id:generate_trace_id(),
  Hex = instrument_id:trace_id_to_hex(TraceId),
  %% Hex should be 32 characters
  ?assertEqual(32, byte_size(Hex)),
  %% Decode back
  Decoded = instrument_id:hex_to_trace_id(Hex),
  ?assertEqual(TraceId, Decoded),
  ok.

span_id_hex_roundtrip_test(_Config) ->
  %% Generate, encode, decode, verify match
  SpanId = instrument_id:generate_span_id(),
  Hex = instrument_id:span_id_to_hex(SpanId),
  %% Hex should be 16 characters
  ?assertEqual(16, byte_size(Hex)),
  %% Decode back
  Decoded = instrument_id:hex_to_span_id(Hex),
  ?assertEqual(SpanId, Decoded),
  ok.

trace_id_undefined_hex_test(_Config) ->
  %% undefined should return all zeros
  Hex = instrument_id:trace_id_to_hex(undefined),
  ?assertEqual(<<"00000000000000000000000000000000">>, Hex),
  ok.

span_id_undefined_hex_test(_Config) ->
  %% undefined should return all zeros
  Hex = instrument_id:span_id_to_hex(undefined),
  ?assertEqual(<<"0000000000000000">>, Hex),
  ok.

is_valid_trace_id_test(_Config) ->
  %% Valid trace ID
  ValidId = instrument_id:generate_trace_id(),
  ?assertEqual(true, instrument_id:is_valid_trace_id(ValidId)),

  %% Invalid: undefined
  ?assertEqual(false, instrument_id:is_valid_trace_id(undefined)),

  %% Invalid: all zeros
  ?assertEqual(false, instrument_id:is_valid_trace_id(<<0:128>>)),

  %% Invalid: wrong size
  ?assertEqual(false, instrument_id:is_valid_trace_id(<<1,2,3,4>>)),

  %% Invalid: not a binary
  ?assertEqual(false, instrument_id:is_valid_trace_id("not-binary")),
  ok.

is_valid_span_id_test(_Config) ->
  %% Valid span ID
  ValidId = instrument_id:generate_span_id(),
  ?assertEqual(true, instrument_id:is_valid_span_id(ValidId)),

  %% Invalid: undefined
  ?assertEqual(false, instrument_id:is_valid_span_id(undefined)),

  %% Invalid: all zeros
  ?assertEqual(false, instrument_id:is_valid_span_id(<<0:64>>)),

  %% Invalid: wrong size
  ?assertEqual(false, instrument_id:is_valid_span_id(<<1,2,3,4>>)),

  %% Invalid: not a binary
  ?assertEqual(false, instrument_id:is_valid_span_id("not-binary")),
  ok.
