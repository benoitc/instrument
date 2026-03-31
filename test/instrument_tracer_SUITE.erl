%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_tracer_SUITE).
-author("benoitc").

-export([
  all/0,
  init_per_suite/1,
  end_per_suite/1,
  init_per_testcase/2,
  end_per_testcase/2
]).

-export([
  get_tracer/1,
  start_and_end_span/1,
  with_span/1,
  with_span_exception/1,
  nested_spans/1,
  span_attributes/1,
  span_events/1,
  span_status/1,
  span_context/1,
  trace_id_generation/1,
  span_exporter/1,
  propagation_across_processes/1
]).

-include("instrument_otel.hrl").

all() ->
  [
    get_tracer,
    start_and_end_span,
    with_span,
    with_span_exception,
    nested_spans,
    span_attributes,
    span_events,
    span_status,
    span_context,
    trace_id_generation,
    span_exporter,
    propagation_across_processes
  ].

init_per_suite(Config) ->
  %% crypto might already be started
  _ = application:ensure_all_started(crypto),
  ok = application:start(instrument),
  Config.

end_per_suite(Config) ->
  ok = application:stop(instrument),
  Config.

init_per_testcase(_, Config) ->
  %% Clean up context between tests
  erlang:erase('$instrument_context'),
  Config.

end_per_testcase(_, _Config) ->
  erlang:erase('$instrument_context'),
  ok.

%% ============================================================================
%% Tracer Tests
%% ============================================================================

get_tracer(_Config) ->
  Tracer = instrument_tracer:get_tracer(<<"my_service">>),
  #tracer{name = <<"my_service">>} = Tracer,

  Tracer2 = instrument_tracer:get_tracer(my_service, #{version => <<"1.0.0">>}),
  #tracer{name = <<"my_service">>, version = <<"1.0.0">>} = Tracer2,
  ok.

start_and_end_span(_Config) ->
  %% No current span initially
  undefined = instrument_tracer:current_span(),

  %% Start span
  Span = instrument_tracer:start_span(<<"test_span">>),
  #span{name = <<"test_span">>} = Span,

  %% Current span should be set
  CurrentSpan = instrument_tracer:current_span(),
  #span{name = <<"test_span">>} = CurrentSpan,

  %% Span should be recording
  true = instrument_tracer:is_recording(),

  %% End span
  ok = instrument_tracer:end_span(),

  %% No current span after end
  undefined = instrument_tracer:current_span(),
  ok.

with_span(_Config) ->
  Result = instrument_tracer:with_span(<<"my_operation">>, fun() ->
    %% Should have a current span
    Span = instrument_tracer:current_span(),
    #span{name = <<"my_operation">>} = Span,
    computed_result
  end),
  computed_result = Result,

  %% No span after with_span returns
  undefined = instrument_tracer:current_span(),
  ok.

with_span_exception(_Config) ->
  try
    instrument_tracer:with_span(<<"failing_operation">>, fun() ->
      throw(my_error)
    end),
    ct:fail(should_have_thrown)
  catch
    throw:my_error ->
      %% Expected
      ok
  end,

  %% Span should be ended even after exception
  undefined = instrument_tracer:current_span(),
  ok.

nested_spans(_Config) ->
  instrument_tracer:with_span(<<"parent">>, fun() ->
    ParentCtx = instrument_tracer:span_ctx(),

    instrument_tracer:with_span(<<"child">>, fun() ->
      ChildSpan = instrument_tracer:current_span(),
      #span{parent_ctx = ParentCtx} = ChildSpan,

      %% Should have same trace_id
      #span_ctx{trace_id = TraceId} = ParentCtx,
      #span_ctx{trace_id = TraceId} = ChildSpan#span.ctx,

      %% But different span_id
      #span_ctx{span_id = ParentSpanId} = ParentCtx,
      #span_ctx{span_id = ChildSpanId} = ChildSpan#span.ctx,
      true = ParentSpanId =/= ChildSpanId
    end)
  end),
  ok.

span_attributes(_Config) ->
  instrument_tracer:with_span(<<"test">>, fun() ->
    %% Set single attribute
    ok = instrument_tracer:set_attribute(<<"key1">>, <<"value1">>),

    %% Set multiple attributes
    ok = instrument_tracer:set_attributes(#{
      <<"key2">> => 42,
      <<"key3">> => true
    }),

    Span = instrument_tracer:current_span(),
    Attrs = Span#span.attributes,
    <<"value1">> = maps:get(<<"key1">>, Attrs),
    42 = maps:get(<<"key2">>, Attrs),
    true = maps:get(<<"key3">>, Attrs)
  end),
  ok.

span_events(_Config) ->
  instrument_tracer:with_span(<<"test">>, fun() ->
    %% Add simple event
    ok = instrument_tracer:add_event(<<"event1">>),

    %% Add event with attributes
    ok = instrument_tracer:add_event(<<"event2">>, #{<<"key">> => <<"value">>}),

    Span = instrument_tracer:current_span(),
    [Event1, Event2] = Span#span.events,
    <<"event1">> = Event1#span_event.name,
    <<"event2">> = Event2#span_event.name,
    #{<<"key">> := <<"value">>} = Event2#span_event.attributes
  end),
  ok.

span_status(_Config) ->
  instrument_tracer:with_span(<<"test">>, fun() ->
    Span1 = instrument_tracer:current_span(),
    unset = Span1#span.status,

    ok = instrument_tracer:set_status(ok),
    Span2 = instrument_tracer:current_span(),
    ok = Span2#span.status,

    ok = instrument_tracer:set_status(error, <<"something went wrong">>),
    Span3 = instrument_tracer:current_span(),
    {error, <<"something went wrong">>} = Span3#span.status
  end),
  ok.

span_context(_Config) ->
  %% No span context initially
  undefined = instrument_tracer:span_ctx(),
  undefined = instrument_tracer:trace_id(),
  undefined = instrument_tracer:span_id(),
  false = instrument_tracer:is_recording(),
  false = instrument_tracer:is_sampled(),

  instrument_tracer:with_span(<<"test">>, fun() ->
    SpanCtx = instrument_tracer:span_ctx(),
    #span_ctx{} = SpanCtx,

    TraceId = instrument_tracer:trace_id(),
    32 = byte_size(TraceId),

    SpanId = instrument_tracer:span_id(),
    16 = byte_size(SpanId),

    true = instrument_tracer:is_recording(),
    true = instrument_tracer:is_sampled()
  end),
  ok.

trace_id_generation(_Config) ->
  %% Generate IDs
  TraceId1 = instrument_id:generate_trace_id(),
  TraceId2 = instrument_id:generate_trace_id(),
  16 = byte_size(TraceId1),
  16 = byte_size(TraceId2),
  true = TraceId1 =/= TraceId2,

  SpanId1 = instrument_id:generate_span_id(),
  SpanId2 = instrument_id:generate_span_id(),
  8 = byte_size(SpanId1),
  8 = byte_size(SpanId2),
  true = SpanId1 =/= SpanId2,

  %% Hex conversion
  TraceIdHex = instrument_id:trace_id_to_hex(TraceId1),
  32 = byte_size(TraceIdHex),
  TraceId1 = instrument_id:hex_to_trace_id(TraceIdHex),

  SpanIdHex = instrument_id:span_id_to_hex(SpanId1),
  16 = byte_size(SpanIdHex),
  SpanId1 = instrument_id:hex_to_span_id(SpanIdHex),

  %% Validation
  true = instrument_id:is_valid_trace_id(TraceId1),
  false = instrument_id:is_valid_trace_id(<<0:128>>),
  false = instrument_id:is_valid_trace_id(undefined),

  true = instrument_id:is_valid_span_id(SpanId1),
  false = instrument_id:is_valid_span_id(<<0:64>>),
  false = instrument_id:is_valid_span_id(undefined),
  ok.

span_exporter(_Config) ->
  Parent = self(),
  Exporter = fun(Span) ->
    Parent ! {exported, Span}
  end,

  ok = instrument_tracer:register_exporter(Exporter),

  instrument_tracer:with_span(<<"exported_span">>, fun() ->
    ok = instrument_tracer:set_status(ok)
  end),

  receive
    {exported, #span{name = <<"exported_span">>}} ->
      ok
  after 1000 ->
    ct:fail(no_export_received)
  end,

  ok = instrument_tracer:unregister_exporter(Exporter),
  ok.

propagation_across_processes(_Config) ->
  Parent = self(),

  instrument_tracer:with_span(<<"parent_span">>, fun() ->
    ParentTraceId = instrument_tracer:trace_id(),

    Pid = instrument_propagation:spawn(fun() ->
      %% Should inherit trace context
      TraceId = instrument_tracer:trace_id(),
      Parent ! {child, TraceId}
    end),

    receive
      {child, ParentTraceId} ->
        %% Same trace ID
        _ = Pid,
        ok
    after 1000 ->
      ct:fail(timeout)
    end
  end),
  ok.
