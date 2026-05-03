%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_propagator_SUITE).
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
  register_propagator_test/1,
  unregister_propagator_test/1,
  list_propagators_test/1,
  tracecontext_inject_test/1,
  tracecontext_extract_test/1,
  baggage_inject_test/1,
  baggage_extract_test/1,
  composite_inject_extract_test/1,
  fields_test/1,
  custom_propagator_test/1,
  %% New tests
  malformed_traceparent_test/1,
  missing_headers_test/1,
  tracestate_limit_test/1,
  cross_service_roundtrip_test/1,
  concurrent_propagation_test/1,
  %% Doc-API coverage
  inject_headers_test/1,
  extract_headers_test/1,
  extract_headers_string_keys_test/1,
  call_with_context_test/1,
  cast_with_context_test/1
]).

all() ->
  [
    register_propagator_test,
    unregister_propagator_test,
    list_propagators_test,
    tracecontext_inject_test,
    tracecontext_extract_test,
    baggage_inject_test,
    baggage_extract_test,
    composite_inject_extract_test,
    fields_test,
    custom_propagator_test,
    %% New tests
    malformed_traceparent_test,
    missing_headers_test,
    tracestate_limit_test,
    cross_service_roundtrip_test,
    concurrent_propagation_test,
    %% Doc-API coverage
    inject_headers_test,
    extract_headers_test,
    extract_headers_string_keys_test,
    call_with_context_test,
    cast_with_context_test
  ].

init_per_suite(Config) ->
  _ = application:ensure_all_started(crypto),
  ok = application:start(instrument),
  Config.

end_per_suite(_Config) ->
  ok = application:stop(instrument),
  ok.

init_per_testcase(_TestCase, Config) ->
  %% Reset to default propagators
  instrument_propagator:set_propagators([
    instrument_propagator_tracecontext,
    instrument_propagator_baggage
  ]),
  Config.

end_per_testcase(_TestCase, _Config) ->
  ok.

%% ============================================================================
%% Test Cases
%% ============================================================================

register_propagator_test(_Config) ->
  %% Create a mock propagator
  meck:new(mock_propagator, [non_strict]),
  meck:expect(mock_propagator, inject, fun(_, Carrier) -> Carrier end),
  meck:expect(mock_propagator, extract, fun(_, Ctx) -> Ctx end),
  meck:expect(mock_propagator, fields, fun() -> [<<"mock-header">>] end),

  ok = instrument_propagator:register(mock_propagator),
  ?assert(lists:member(mock_propagator, instrument_propagator:list())),

  %% Registering again should be idempotent
  ok = instrument_propagator:register(mock_propagator),
  PropCount = length([P || P <- instrument_propagator:list(), P =:= mock_propagator]),
  ?assertEqual(1, PropCount),

  meck:unload(mock_propagator),
  ok.

unregister_propagator_test(_Config) ->
  meck:new(mock_propagator2, [non_strict]),
  meck:expect(mock_propagator2, inject, fun(_, Carrier) -> Carrier end),
  meck:expect(mock_propagator2, extract, fun(_, Ctx) -> Ctx end),
  meck:expect(mock_propagator2, fields, fun() -> [] end),

  ok = instrument_propagator:register(mock_propagator2),
  ?assert(lists:member(mock_propagator2, instrument_propagator:list())),

  ok = instrument_propagator:unregister(mock_propagator2),
  ?assertNot(lists:member(mock_propagator2, instrument_propagator:list())),

  meck:unload(mock_propagator2),
  ok.

list_propagators_test(_Config) ->
  Propagators = instrument_propagator:list(),
  ?assert(lists:member(instrument_propagator_tracecontext, Propagators)),
  ?assert(lists:member(instrument_propagator_baggage, Propagators)),
  ok.

tracecontext_inject_test(_Config) ->
  TraceId = instrument_id:generate_trace_id(),
  SpanId = instrument_id:generate_span_id(),
  SpanCtx = #span_ctx{
    trace_id = TraceId,
    span_id = SpanId,
    trace_flags = 1,
    trace_state = [{<<"vendor">>, <<"value">>}],
    is_remote = false
  },
  Ctx = instrument_context:set_value(instrument_context:new(), span_ctx, SpanCtx),

  Carrier = instrument_propagator_tracecontext:inject(Ctx, #{}),

  ?assert(maps:is_key(<<"traceparent">>, Carrier)),
  ?assert(maps:is_key(<<"tracestate">>, Carrier)),

  TraceParent = maps:get(<<"traceparent">>, Carrier),
  ?assertMatch(<<"00-", _:256/bitstring, "-", _:128/bitstring, "-01">>, TraceParent),

  TraceState = maps:get(<<"tracestate">>, Carrier),
  ?assertEqual(<<"vendor=value">>, TraceState),
  ok.

tracecontext_extract_test(_Config) ->
  Carrier = #{
    <<"traceparent">> => <<"00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01">>,
    <<"tracestate">> => <<"vendor=value,other=data">>
  },

  Ctx = instrument_propagator_tracecontext:extract(Carrier, instrument_context:new()),
  SpanCtx = instrument_context:get_value(Ctx, span_ctx),

  ?assertNotEqual(undefined, SpanCtx),
  ?assertEqual(instrument_id:hex_to_trace_id(<<"0af7651916cd43dd8448eb211c80319c">>),
               SpanCtx#span_ctx.trace_id),
  ?assertEqual(instrument_id:hex_to_span_id(<<"b7ad6b7169203331">>),
               SpanCtx#span_ctx.span_id),
  ?assertEqual(1, SpanCtx#span_ctx.trace_flags),
  ?assertEqual(true, SpanCtx#span_ctx.is_remote),
  ?assertEqual([{<<"vendor">>, <<"value">>}, {<<"other">>, <<"data">>}],
               SpanCtx#span_ctx.trace_state),
  ok.

baggage_inject_test(_Config) ->
  Ctx = instrument_context:new(),
  %% Baggage uses {Value, Metadata} format
  Baggage = #{<<"key1">> => {<<"value1">>, #{}}, <<"key2">> => {<<"value2">>, #{}}},
  CtxWithBaggage = instrument_baggage:to_context(Ctx, Baggage),

  Carrier = instrument_propagator_baggage:inject(CtxWithBaggage, #{}),

  ?assert(maps:is_key(<<"baggage">>, Carrier)),
  BaggageHeader = maps:get(<<"baggage">>, Carrier),
  ?assert(binary:match(BaggageHeader, <<"key1=value1">>) =/= nomatch orelse
          binary:match(BaggageHeader, <<"key2=value2">>) =/= nomatch),
  ok.

baggage_extract_test(_Config) ->
  Carrier = #{
    <<"baggage">> => <<"key1=value1,key2=value2">>
  },

  Ctx = instrument_propagator_baggage:extract(Carrier, instrument_context:new()),
  Baggage = instrument_baggage:from_context(Ctx),

  %% Baggage uses {Value, Metadata} format
  ?assertEqual({<<"value1">>, #{}}, maps:get(<<"key1">>, Baggage)),
  ?assertEqual({<<"value2">>, #{}}, maps:get(<<"key2">>, Baggage)),
  ok.

composite_inject_extract_test(_Config) ->
  %% Create a span context and baggage
  TraceId = instrument_id:generate_trace_id(),
  SpanId = instrument_id:generate_span_id(),
  SpanCtx = #span_ctx{
    trace_id = TraceId,
    span_id = SpanId,
    trace_flags = 1,
    trace_state = [],
    is_remote = false
  },
  Ctx1 = instrument_context:set_value(instrument_context:new(), span_ctx, SpanCtx),
  %% Baggage uses {Value, Metadata} format
  Ctx2 = instrument_baggage:to_context(Ctx1, #{<<"user_id">> => {<<"123">>, #{}}}),

  %% Inject using composite propagator
  Carrier = instrument_propagator:inject(Ctx2, #{}),

  ?assert(maps:is_key(<<"traceparent">>, Carrier)),
  ?assert(maps:is_key(<<"baggage">>, Carrier)),

  %% Extract using composite propagator
  ExtractedCtx = instrument_propagator:extract(Carrier),

  ExtractedSpanCtx = instrument_context:get_value(ExtractedCtx, span_ctx),
  ?assertNotEqual(undefined, ExtractedSpanCtx),
  ?assertEqual(TraceId, ExtractedSpanCtx#span_ctx.trace_id),

  ExtractedBaggage = instrument_baggage:from_context(ExtractedCtx),
  ?assertEqual({<<"123">>, #{}}, maps:get(<<"user_id">>, ExtractedBaggage)),
  ok.

fields_test(_Config) ->
  Fields = instrument_propagator:fields(),
  ?assert(lists:member(<<"traceparent">>, Fields)),
  ?assert(lists:member(<<"tracestate">>, Fields)),
  ?assert(lists:member(<<"baggage">>, Fields)),
  ok.

custom_propagator_test(_Config) ->
  %% Create a custom propagator
  meck:new(custom_propagator, [non_strict]),
  meck:expect(custom_propagator, inject, fun(Ctx, Carrier) ->
    case instrument_context:get_value(Ctx, custom_key) of
      undefined -> Carrier;
      Value -> maps:put(<<"x-custom">>, Value, Carrier)
    end
  end),
  meck:expect(custom_propagator, extract, fun(Carrier, Ctx) ->
    case maps:get(<<"x-custom">>, Carrier, undefined) of
      undefined -> Ctx;
      Value -> instrument_context:set_value(Ctx, custom_key, Value)
    end
  end),
  meck:expect(custom_propagator, fields, fun() -> [<<"x-custom">>] end),

  ok = instrument_propagator:register(custom_propagator),

  %% Test injection
  Ctx = instrument_context:set_value(instrument_context:new(), custom_key, <<"custom-value">>),
  Carrier = instrument_propagator:inject(Ctx, #{}),
  ?assertEqual(<<"custom-value">>, maps:get(<<"x-custom">>, Carrier)),

  %% Test extraction
  ExtractedCtx = instrument_propagator:extract(#{<<"x-custom">> => <<"extracted-value">>}),
  ?assertEqual(<<"extracted-value">>, instrument_context:get_value(ExtractedCtx, custom_key)),

  %% Test fields
  ?assert(lists:member(<<"x-custom">>, instrument_propagator:fields())),

  ok = instrument_propagator:unregister(custom_propagator),
  meck:unload(custom_propagator),
  ok.

%% ============================================================================
%% New Test Cases
%% ============================================================================

malformed_traceparent_test(_Config) ->
  %% Test handling of malformed traceparent headers

  %% Invalid version ff (only ff is invalid per W3C spec)
  Carrier1 = #{<<"traceparent">> => <<"ff-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01">>},
  Ctx1 = instrument_propagator_tracecontext:extract(Carrier1, instrument_context:new()),
  SpanCtx1 = instrument_context:get_value(Ctx1, span_ctx),
  ?assertEqual(undefined, SpanCtx1),

  %% Too short
  Carrier2 = #{<<"traceparent">> => <<"00-abc-def-01">>},
  Ctx2 = instrument_propagator_tracecontext:extract(Carrier2, instrument_context:new()),
  SpanCtx2 = instrument_context:get_value(Ctx2, span_ctx),
  ?assertEqual(undefined, SpanCtx2),

  %% Empty
  Carrier3 = #{<<"traceparent">> => <<"">>},
  Ctx3 = instrument_propagator_tracecontext:extract(Carrier3, instrument_context:new()),
  SpanCtx3 = instrument_context:get_value(Ctx3, span_ctx),
  ?assertEqual(undefined, SpanCtx3),

  %% Invalid characters
  Carrier4 = #{<<"traceparent">> => <<"00-ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ-ZZZZZZZZZZZZZZZZ-01">>},
  Ctx4 = instrument_propagator_tracecontext:extract(Carrier4, instrument_context:new()),
  SpanCtx4 = instrument_context:get_value(Ctx4, span_ctx),
  ?assertEqual(undefined, SpanCtx4),

  %% Version > 00 should be accepted per W3C spec (forward compatibility)
  Carrier5 = #{<<"traceparent">> => <<"01-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01">>},
  Ctx5 = instrument_propagator_tracecontext:extract(Carrier5, instrument_context:new()),
  SpanCtx5 = instrument_context:get_value(Ctx5, span_ctx),
  ?assertNotEqual(undefined, SpanCtx5),
  ?assertEqual(1, SpanCtx5#span_ctx.trace_flags),
  ok.

missing_headers_test(_Config) ->
  %% Test extraction when headers are missing

  %% Empty carrier
  Ctx1 = instrument_propagator:extract(#{}),
  SpanCtx1 = instrument_context:get_value(Ctx1, span_ctx),
  ?assertEqual(undefined, SpanCtx1),

  %% No baggage
  Baggage1 = instrument_baggage:from_context(Ctx1),
  ?assertEqual(#{}, Baggage1),

  %% Only baggage, no traceparent
  Carrier2 = #{<<"baggage">> => <<"key=value">>},
  Ctx2 = instrument_propagator:extract(Carrier2),
  SpanCtx2 = instrument_context:get_value(Ctx2, span_ctx),
  ?assertEqual(undefined, SpanCtx2),
  Baggage2 = instrument_baggage:from_context(Ctx2),
  ?assertEqual({<<"value">>, #{}}, maps:get(<<"key">>, Baggage2)),
  ok.

tracestate_limit_test(_Config) ->
  %% Test handling of tracestate with many entries
  TraceId = instrument_id:generate_trace_id(),
  SpanId = instrument_id:generate_span_id(),

  %% Create tracestate with many entries
  TraceStateEntries = [{iolist_to_binary([<<"vendor">>, integer_to_binary(I)]),
                        iolist_to_binary([<<"value">>, integer_to_binary(I)])}
                       || I <- lists:seq(1, 32)],

  SpanCtx = #span_ctx{
    trace_id = TraceId,
    span_id = SpanId,
    trace_flags = 1,
    trace_state = TraceStateEntries,
    is_remote = false
  },
  Ctx = instrument_context:set_value(instrument_context:new(), span_ctx, SpanCtx),

  %% Inject
  Carrier = instrument_propagator_tracecontext:inject(Ctx, #{}),
  ?assert(maps:is_key(<<"tracestate">>, Carrier)),

  %% Extract and verify some entries preserved
  ExtractedCtx = instrument_propagator_tracecontext:extract(Carrier, instrument_context:new()),
  ExtractedSpanCtx = instrument_context:get_value(ExtractedCtx, span_ctx),
  ?assertNotEqual(undefined, ExtractedSpanCtx),
  ?assert(length(ExtractedSpanCtx#span_ctx.trace_state) > 0),
  ok.

cross_service_roundtrip_test(_Config) ->
  %% Test full inject/extract cycle simulating cross-service call

  %% Service A creates a span and injects
  TraceId = instrument_id:generate_trace_id(),
  SpanId = instrument_id:generate_span_id(),
  OriginalSpanCtx = #span_ctx{
    trace_id = TraceId,
    span_id = SpanId,
    trace_flags = 1,
    trace_state = [{<<"acme">>, <<"p:1">>}],
    is_remote = false
  },
  CtxA = instrument_context:set_value(instrument_context:new(), span_ctx, OriginalSpanCtx),
  BaggageA = #{<<"user_id">> => {<<"12345">>, #{}}},
  CtxAWithBaggage = instrument_baggage:to_context(CtxA, BaggageA),

  %% Inject into HTTP headers (carrier)
  Carrier = instrument_propagator:inject(CtxAWithBaggage, #{}),

  %% Service B extracts from HTTP headers
  CtxB = instrument_propagator:extract(Carrier),

  %% Verify trace context preserved
  ExtractedSpanCtx = instrument_context:get_value(CtxB, span_ctx),
  ?assertEqual(TraceId, ExtractedSpanCtx#span_ctx.trace_id),
  ?assertEqual(SpanId, ExtractedSpanCtx#span_ctx.span_id),
  ?assertEqual(1, ExtractedSpanCtx#span_ctx.trace_flags),
  ?assertEqual(true, ExtractedSpanCtx#span_ctx.is_remote),

  %% Verify baggage preserved
  ExtractedBaggage = instrument_baggage:from_context(CtxB),
  ?assertEqual({<<"12345">>, #{}}, maps:get(<<"user_id">>, ExtractedBaggage)),
  ok.

concurrent_propagation_test(_Config) ->
  %% Test thread-safe propagation
  Self = self(),
  NumProcesses = 50,

  %% Spawn processes that inject/extract concurrently
  Pids = [spawn_link(fun() ->
    TraceId = instrument_id:generate_trace_id(),
    SpanId = instrument_id:generate_span_id(),
    SpanCtx = #span_ctx{
      trace_id = TraceId,
      span_id = SpanId,
      trace_flags = 1,
      trace_state = [],
      is_remote = false
    },
    Ctx = instrument_context:set_value(instrument_context:new(), span_ctx, SpanCtx),

    %% Inject
    Carrier = instrument_propagator:inject(Ctx, #{}),

    %% Extract
    ExtractedCtx = instrument_propagator:extract(Carrier),
    ExtractedSpanCtx = instrument_context:get_value(ExtractedCtx, span_ctx),

    %% Verify
    Match = (TraceId =:= ExtractedSpanCtx#span_ctx.trace_id andalso
             SpanId =:= ExtractedSpanCtx#span_ctx.span_id),
    Self ! {self(), Match}
  end) || _ <- lists:seq(1, NumProcesses)],

  %% Collect results
  Results = lists:map(fun(Pid) ->
    receive {Pid, Match} -> Match
    after 5000 -> false
    end
  end, Pids),

  %% All should match
  ?assert(lists:all(fun(R) -> R =:= true end, Results)),
  ok.

%% ============================================================================
%% Doc-API coverage: instrument_propagation
%% ============================================================================

inject_headers_test(_Config) ->
  TraceId = instrument_id:generate_trace_id(),
  SpanId = instrument_id:generate_span_id(),
  SpanCtx = #span_ctx{
    trace_id = TraceId,
    span_id = SpanId,
    trace_flags = 1,
    trace_state = [],
    is_remote = false
  },
  Ctx = instrument_context:set_value(instrument_context:new(), span_ctx, SpanCtx),
  Headers = instrument_propagation:inject_headers(Ctx),
  ?assert(is_list(Headers)),
  ?assertNotEqual(undefined, lists:keyfind(<<"traceparent">>, 1, Headers)),
  {<<"traceparent">>, TP} = lists:keyfind(<<"traceparent">>, 1, Headers),
  ?assertMatch(<<"00-", _:256/bitstring, "-", _:128/bitstring, "-01">>, TP),
  ok.

extract_headers_test(_Config) ->
  Headers = [
    {<<"traceparent">>,
      <<"00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01">>}
  ],
  Ctx = instrument_propagation:extract_headers(Headers),
  SpanCtx = instrument_context:get_value(Ctx, span_ctx),
  ?assertNotEqual(undefined, SpanCtx),
  ?assertEqual(instrument_id:hex_to_trace_id(<<"0af7651916cd43dd8448eb211c80319c">>),
               SpanCtx#span_ctx.trace_id),
  ?assertEqual(instrument_id:hex_to_span_id(<<"b7ad6b7169203331">>),
               SpanCtx#span_ctx.span_id),
  ?assertEqual(true, SpanCtx#span_ctx.is_remote),
  ok.

extract_headers_string_keys_test(_Config) ->
  %% Header keys often come from HTTP libs as strings/atoms with mixed case.
  %% extract_headers/1 normalises to lowercase binary.
  Headers = [
    {"Traceparent",
      "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"},
    {<<"BAGGAGE">>, <<"key1=v1">>}
  ],
  Ctx = instrument_propagation:extract_headers(Headers),
  SpanCtx = instrument_context:get_value(Ctx, span_ctx),
  ?assertNotEqual(undefined, SpanCtx),
  ok.

call_with_context_test(_Config) ->
  %% Start a tiny gen_server that unwraps {'$instrument_call', Ctx, Req}
  %% and replies with the trace_id it sees in the context.
  {ok, Pid} = ctx_echo_server:start_link(),
  try
    %% Without a span, ctx is empty; server sees no span_ctx.
    R0 = instrument_propagation:call_with_context(Pid, who_am_i),
    ?assertEqual(no_span, R0),

    %% With a span, the server should see the span_ctx.
    instrument_tracer:with_span(<<"caller">>, fun() ->
      ExpectedTraceId = instrument_tracer:trace_id(),
      R1 = instrument_propagation:call_with_context(Pid, who_am_i),
      ?assertMatch({trace_id, _}, R1),
      {trace_id, GotHex} = R1,
      ?assertEqual(ExpectedTraceId, GotHex),

      %% /3 form with explicit timeout
      R2 = instrument_propagation:call_with_context(Pid, who_am_i, 5000),
      ?assertMatch({trace_id, _}, R2)
    end)
  after
    gen_server:stop(Pid)
  end,
  ok.

cast_with_context_test(_Config) ->
  {ok, Pid} = ctx_echo_server:start_link(),
  try
    Self = self(),
    instrument_tracer:with_span(<<"caster">>, fun() ->
      ExpectedTraceId = instrument_tracer:trace_id(),
      ok = instrument_propagation:cast_with_context(Pid, {report_to, Self}),
      receive
        {ctx_seen, GotHex} ->
          ?assertEqual(ExpectedTraceId, GotHex)
      after 2000 ->
          ct:fail(no_cast_response)
      end
    end)
  after
    gen_server:stop(Pid)
  end,
  ok.
