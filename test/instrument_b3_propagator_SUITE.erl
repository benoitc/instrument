%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_b3_propagator_SUITE).
-author("benoitc").

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("instrument_otel.hrl").

-export([
  all/0,
  init_per_suite/1,
  end_per_suite/1,
  init_per_testcase/2,
  end_per_testcase/2
]).

-export([
  %% B3 Single Header Tests
  b3_single_inject_test/1,
  b3_single_extract_test/1,
  b3_single_extract_no_parent_test/1,
  b3_single_extract_sampling_only_test/1,
  b3_single_extract_debug_test/1,
  b3_single_extract_64bit_traceid_test/1,
  %% B3 Multi Header Tests
  b3_multi_inject_test/1,
  b3_multi_extract_test/1,
  b3_multi_extract_flags_test/1,
  %% Roundtrip and Edge Cases
  b3_roundtrip_test/1,
  b3_invalid_ids_rejected_test/1,
  b3_config_propagator_test/1,
  %% B3 ParentSpanId injection tests (OTel spec compliance)
  b3_single_inject_parent_spanid_test/1,
  b3_single_inject_no_parent_test/1
]).

all() ->
  [
    %% B3 Single Header Tests
    b3_single_inject_test,
    b3_single_extract_test,
    b3_single_extract_no_parent_test,
    b3_single_extract_sampling_only_test,
    b3_single_extract_debug_test,
    b3_single_extract_64bit_traceid_test,
    %% B3 Multi Header Tests
    b3_multi_inject_test,
    b3_multi_extract_test,
    b3_multi_extract_flags_test,
    %% Roundtrip and Edge Cases
    b3_roundtrip_test,
    b3_invalid_ids_rejected_test,
    b3_config_propagator_test,
    %% B3 ParentSpanId injection tests (OTel spec compliance)
    b3_single_inject_parent_spanid_test,
    b3_single_inject_no_parent_test
  ].

init_per_suite(Config) ->
  _ = application:ensure_all_started(crypto),
  ok = application:start(instrument),
  Config.

end_per_suite(_Config) ->
  ok = application:stop(instrument),
  ok.

init_per_testcase(_TestCase, Config) ->
  Config.

end_per_testcase(_TestCase, _Config) ->
  ok.

%% ============================================================================
%% B3 Single Header Test Cases
%% ============================================================================

b3_single_inject_test(_Config) ->
  TraceId = instrument_id:generate_trace_id(),
  SpanId = instrument_id:generate_span_id(),
  SpanCtx = #span_ctx{
    trace_id = TraceId,
    span_id = SpanId,
    trace_flags = 1,
    is_remote = false
  },
  Ctx = instrument_context:set_value(instrument_context:new(), span_ctx, SpanCtx),

  Carrier = instrument_propagator_b3:inject(Ctx, #{}),

  ?assert(maps:is_key(<<"b3">>, Carrier)),
  B3Header = maps:get(<<"b3">>, Carrier),

  %% Format: {TraceId}-{SpanId}-{SamplingState}
  Parts = binary:split(B3Header, <<"-">>, [global]),
  ?assertEqual(3, length(Parts)),

  [TraceIdHex, SpanIdHex, SamplingState] = Parts,
  ?assertEqual(32, byte_size(TraceIdHex)),
  ?assertEqual(16, byte_size(SpanIdHex)),
  ?assertEqual(<<"1">>, SamplingState),
  ok.

b3_single_extract_test(_Config) ->
  %% Full format with parent span ID
  Carrier = #{
    <<"b3">> => <<"0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-1-05e3ac9a4f6e3b90">>
  },

  Ctx = instrument_propagator_b3:extract(Carrier, instrument_context:new()),
  SpanCtx = instrument_context:get_value(Ctx, span_ctx),

  ?assertNotEqual(undefined, SpanCtx),
  ?assertEqual(instrument_id:hex_to_trace_id(<<"0af7651916cd43dd8448eb211c80319c">>),
               SpanCtx#span_ctx.trace_id),
  ?assertEqual(instrument_id:hex_to_span_id(<<"b7ad6b7169203331">>),
               SpanCtx#span_ctx.span_id),
  ?assertEqual(1, SpanCtx#span_ctx.trace_flags),
  ?assertEqual(true, SpanCtx#span_ctx.is_remote),
  ok.

b3_single_extract_no_parent_test(_Config) ->
  %% Format without parent span ID
  Carrier = #{
    <<"b3">> => <<"0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-1">>
  },

  Ctx = instrument_propagator_b3:extract(Carrier, instrument_context:new()),
  SpanCtx = instrument_context:get_value(Ctx, span_ctx),

  ?assertNotEqual(undefined, SpanCtx),
  ?assertEqual(instrument_id:hex_to_trace_id(<<"0af7651916cd43dd8448eb211c80319c">>),
               SpanCtx#span_ctx.trace_id),
  ?assertEqual(1, SpanCtx#span_ctx.trace_flags),
  ok.

b3_single_extract_sampling_only_test(_Config) ->
  %% "0" means sampling deny - no trace context
  Carrier0 = #{<<"b3">> => <<"0">>},
  Ctx0 = instrument_propagator_b3:extract(Carrier0, instrument_context:new()),
  SpanCtx0 = instrument_context:get_value(Ctx0, span_ctx),
  ?assertEqual(undefined, SpanCtx0),

  %% "1" means sampling accept - no trace context
  Carrier1 = #{<<"b3">> => <<"1">>},
  Ctx1 = instrument_propagator_b3:extract(Carrier1, instrument_context:new()),
  SpanCtx1 = instrument_context:get_value(Ctx1, span_ctx),
  ?assertEqual(undefined, SpanCtx1),
  ok.

b3_single_extract_debug_test(_Config) ->
  %% "d" sampling state means debug (implies sampled)
  Carrier = #{
    <<"b3">> => <<"0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-d">>
  },

  Ctx = instrument_propagator_b3:extract(Carrier, instrument_context:new()),
  SpanCtx = instrument_context:get_value(Ctx, span_ctx),

  ?assertNotEqual(undefined, SpanCtx),
  ?assertEqual(1, SpanCtx#span_ctx.trace_flags),  %% Debug implies sampled
  ok.

b3_single_extract_64bit_traceid_test(_Config) ->
  %% 64-bit (16 char) trace ID should be zero-padded to 128-bit
  Carrier = #{
    <<"b3">> => <<"8448eb211c80319c-b7ad6b7169203331-1">>
  },

  Ctx = instrument_propagator_b3:extract(Carrier, instrument_context:new()),
  SpanCtx = instrument_context:get_value(Ctx, span_ctx),

  ?assertNotEqual(undefined, SpanCtx),
  %% Should be padded with zeros on the left
  ?assertEqual(instrument_id:hex_to_trace_id(<<"00000000000000008448eb211c80319c">>),
               SpanCtx#span_ctx.trace_id),
  ok.

%% ============================================================================
%% B3 Multi Header Test Cases
%% ============================================================================

b3_multi_inject_test(_Config) ->
  TraceId = instrument_id:generate_trace_id(),
  SpanId = instrument_id:generate_span_id(),
  SpanCtx = #span_ctx{
    trace_id = TraceId,
    span_id = SpanId,
    trace_flags = 1,
    is_remote = false
  },
  Ctx = instrument_context:set_value(instrument_context:new(), span_ctx, SpanCtx),

  Carrier = instrument_propagator_b3_multi:inject(Ctx, #{}),

  ?assert(maps:is_key(<<"x-b3-traceid">>, Carrier)),
  ?assert(maps:is_key(<<"x-b3-spanid">>, Carrier)),
  ?assert(maps:is_key(<<"x-b3-sampled">>, Carrier)),

  ?assertEqual(instrument_id:trace_id_to_hex(TraceId), maps:get(<<"x-b3-traceid">>, Carrier)),
  ?assertEqual(instrument_id:span_id_to_hex(SpanId), maps:get(<<"x-b3-spanid">>, Carrier)),
  ?assertEqual(<<"1">>, maps:get(<<"x-b3-sampled">>, Carrier)),
  ok.

b3_multi_extract_test(_Config) ->
  Carrier = #{
    <<"x-b3-traceid">> => <<"0af7651916cd43dd8448eb211c80319c">>,
    <<"x-b3-spanid">> => <<"b7ad6b7169203331">>,
    <<"x-b3-sampled">> => <<"1">>
  },

  Ctx = instrument_propagator_b3_multi:extract(Carrier, instrument_context:new()),
  SpanCtx = instrument_context:get_value(Ctx, span_ctx),

  ?assertNotEqual(undefined, SpanCtx),
  ?assertEqual(instrument_id:hex_to_trace_id(<<"0af7651916cd43dd8448eb211c80319c">>),
               SpanCtx#span_ctx.trace_id),
  ?assertEqual(instrument_id:hex_to_span_id(<<"b7ad6b7169203331">>),
               SpanCtx#span_ctx.span_id),
  ?assertEqual(1, SpanCtx#span_ctx.trace_flags),
  ?assertEqual(true, SpanCtx#span_ctx.is_remote),
  ok.

b3_multi_extract_flags_test(_Config) ->
  %% X-B3-Flags: 1 implies debug/sampled, overrides X-B3-Sampled
  Carrier = #{
    <<"x-b3-traceid">> => <<"0af7651916cd43dd8448eb211c80319c">>,
    <<"x-b3-spanid">> => <<"b7ad6b7169203331">>,
    <<"x-b3-sampled">> => <<"0">>,  %% Would be not sampled
    <<"x-b3-flags">> => <<"1">>      %% But flags=1 overrides
  },

  Ctx = instrument_propagator_b3_multi:extract(Carrier, instrument_context:new()),
  SpanCtx = instrument_context:get_value(Ctx, span_ctx),

  ?assertNotEqual(undefined, SpanCtx),
  ?assertEqual(1, SpanCtx#span_ctx.trace_flags),  %% Flags overrides sampled
  ok.

%% ============================================================================
%% Roundtrip and Edge Cases
%% ============================================================================

b3_roundtrip_test(_Config) ->
  %% Test inject then extract preserves context
  TraceId = instrument_id:generate_trace_id(),
  SpanId = instrument_id:generate_span_id(),
  OriginalSpanCtx = #span_ctx{
    trace_id = TraceId,
    span_id = SpanId,
    trace_flags = 1,
    is_remote = false
  },
  Ctx = instrument_context:set_value(instrument_context:new(), span_ctx, OriginalSpanCtx),

  %% B3 Single Header roundtrip
  CarrierB3 = instrument_propagator_b3:inject(Ctx, #{}),
  ExtractedCtxB3 = instrument_propagator_b3:extract(CarrierB3, instrument_context:new()),
  ExtractedB3 = instrument_context:get_value(ExtractedCtxB3, span_ctx),
  ?assertEqual(TraceId, ExtractedB3#span_ctx.trace_id),
  ?assertEqual(SpanId, ExtractedB3#span_ctx.span_id),
  ?assertEqual(1, ExtractedB3#span_ctx.trace_flags),

  %% B3 Multi Header roundtrip
  CarrierMulti = instrument_propagator_b3_multi:inject(Ctx, #{}),
  ExtractedCtxMulti = instrument_propagator_b3_multi:extract(CarrierMulti, instrument_context:new()),
  ExtractedMulti = instrument_context:get_value(ExtractedCtxMulti, span_ctx),
  ?assertEqual(TraceId, ExtractedMulti#span_ctx.trace_id),
  ?assertEqual(SpanId, ExtractedMulti#span_ctx.span_id),
  ?assertEqual(1, ExtractedMulti#span_ctx.trace_flags),
  ok.

b3_invalid_ids_rejected_test(_Config) ->
  %% All-zero trace ID should be rejected
  Carrier1 = #{
    <<"b3">> => <<"00000000000000000000000000000000-b7ad6b7169203331-1">>
  },
  Ctx1 = instrument_propagator_b3:extract(Carrier1, instrument_context:new()),
  ?assertEqual(undefined, instrument_context:get_value(Ctx1, span_ctx)),

  %% All-zero span ID should be rejected
  Carrier2 = #{
    <<"b3">> => <<"0af7651916cd43dd8448eb211c80319c-0000000000000000-1">>
  },
  Ctx2 = instrument_propagator_b3:extract(Carrier2, instrument_context:new()),
  ?assertEqual(undefined, instrument_context:get_value(Ctx2, span_ctx)),

  %% Multi-header: all-zero trace ID
  Carrier3 = #{
    <<"x-b3-traceid">> => <<"00000000000000000000000000000000">>,
    <<"x-b3-spanid">> => <<"b7ad6b7169203331">>
  },
  Ctx3 = instrument_propagator_b3_multi:extract(Carrier3, instrument_context:new()),
  ?assertEqual(undefined, instrument_context:get_value(Ctx3, span_ctx)),

  %% Malformed header should be gracefully handled
  Carrier4 = #{<<"b3">> => <<"invalid">>},
  Ctx4 = instrument_propagator_b3:extract(Carrier4, instrument_context:new()),
  ?assertEqual(undefined, instrument_context:get_value(Ctx4, span_ctx)),
  ok.

b3_config_propagator_test(_Config) ->
  %% Test that B3 propagators can be configured via OTEL_PROPAGATORS
  OldValue = os:getenv("OTEL_PROPAGATORS"),
  try
    os:putenv("OTEL_PROPAGATORS", "b3"),
    instrument_config:init(),
    Propagators = instrument_config:get_propagators(),
    ?assert(lists:member(instrument_propagator_b3, Propagators)),

    os:putenv("OTEL_PROPAGATORS", "b3multi"),
    instrument_config:init(),
    Propagators2 = instrument_config:get_propagators(),
    ?assert(lists:member(instrument_propagator_b3_multi, Propagators2))
  after
    case OldValue of
      false -> os:unsetenv("OTEL_PROPAGATORS");
      _ -> os:putenv("OTEL_PROPAGATORS", OldValue)
    end
  end,
  ok.

%% ============================================================================
%% B3 ParentSpanId Injection Tests (OTel Spec Compliance)
%% ============================================================================

%% Test that inject includes parent span ID for nested spans
b3_single_inject_parent_spanid_test(_Config) ->
  %% Create a parent span
  instrument_tracer:with_span(<<"parent_span">>, fun() ->
    ParentCtx = instrument_tracer:span_ctx(),
    ParentSpanId = instrument_tracer:span_id(),

    %% Create a child span
    instrument_tracer:with_span(<<"child_span">>, fun() ->
      %% Get the child's context
      _ChildCtx = instrument_tracer:span_ctx(),
      ChildSpanId = instrument_tracer:span_id(),

      %% Create full context with the span record
      FullCtx = instrument_context:current(),

      %% Inject B3 header
      Carrier = instrument_propagator_b3:inject(FullCtx, #{}),

      ?assert(maps:is_key(<<"b3">>, Carrier)),
      B3Header = maps:get(<<"b3">>, Carrier),

      %% Header format should be: {TraceId}-{SpanId}-{SamplingState}-{ParentSpanId}
      Parts = binary:split(B3Header, <<"-">>, [global]),

      %% Should have 4 parts when parent exists
      ?assertEqual(4, length(Parts)),

      [TraceIdHex, SpanIdHex, SamplingState, ParentSpanIdHex] = Parts,

      %% Verify IDs
      ?assertEqual(instrument_id:trace_id_to_hex(ParentCtx#span_ctx.trace_id), TraceIdHex),
      ?assertEqual(ChildSpanId, SpanIdHex),
      ?assertEqual(<<"1">>, SamplingState),
      ?assertEqual(ParentSpanId, ParentSpanIdHex)
    end)
  end),
  ok.

%% Test that inject without parent (root span) has 3 parts only
b3_single_inject_no_parent_test(_Config) ->
  %% Create a root span (no parent)
  instrument_tracer:with_span(<<"root_span">>, fun() ->
    FullCtx = instrument_context:current(),

    %% Inject B3 header
    Carrier = instrument_propagator_b3:inject(FullCtx, #{}),

    ?assert(maps:is_key(<<"b3">>, Carrier)),
    B3Header = maps:get(<<"b3">>, Carrier),

    %% Header format should be: {TraceId}-{SpanId}-{SamplingState} (no parent)
    Parts = binary:split(B3Header, <<"-">>, [global]),

    %% Should have 3 parts when no parent
    ?assertEqual(3, length(Parts)),

    [_TraceIdHex, _SpanIdHex, SamplingState] = Parts,
    ?assertEqual(<<"1">>, SamplingState)
  end),
  ok.
