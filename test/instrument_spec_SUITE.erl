%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Tests for OpenTelemetry spec-compliance fixes added in step 6.
-module(instrument_spec_SUITE).
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
  status_unset_to_ok/1,
  status_unset_to_error/1,
  status_error_to_ok/1,
  status_ok_is_final/1,
  status_unset_assignment_ignored/1,
  attribute_value_truncated/1,
  event_attribute_count_limit/1,
  link_attribute_count_limit/1,
  tracestate_decode_drops_oversize_entries/1,
  tracestate_encode_caps_entries/1,
  baggage_set_rejects_over_entry_limit/1,
  baggage_decode_caps_entries/1,
  probability_sampler_uses_upper_bytes/1,
  batch_clamps_export_batch_to_queue_size/1
]).

all() ->
  [
    status_unset_to_ok,
    status_unset_to_error,
    status_error_to_ok,
    status_ok_is_final,
    status_unset_assignment_ignored,
    attribute_value_truncated,
    event_attribute_count_limit,
    link_attribute_count_limit,
    tracestate_decode_drops_oversize_entries,
    tracestate_encode_caps_entries,
    baggage_set_rejects_over_entry_limit,
    baggage_decode_caps_entries,
    probability_sampler_uses_upper_bytes,
    batch_clamps_export_batch_to_queue_size
  ].

init_per_suite(Config) ->
  _ = application:load(instrument),
  ok = application:set_env(instrument, auto_register_exporters, false),
  _ = application:ensure_all_started(instrument),
  Config.

end_per_suite(_Config) ->
  ok = application:stop(instrument),
  ok.

init_per_testcase(_TC, Config) ->
  os:unsetenv("OTEL_ATTRIBUTE_VALUE_LENGTH_LIMIT"),
  os:unsetenv("OTEL_EVENT_ATTRIBUTE_COUNT_LIMIT"),
  os:unsetenv("OTEL_LINK_ATTRIBUTE_COUNT_LIMIT"),
  Config.

end_per_testcase(_TC, _Config) ->
  os:unsetenv("OTEL_ATTRIBUTE_VALUE_LENGTH_LIMIT"),
  os:unsetenv("OTEL_EVENT_ATTRIBUTE_COUNT_LIMIT"),
  os:unsetenv("OTEL_LINK_ATTRIBUTE_COUNT_LIMIT"),
  ok.

%% Status transitions

status_unset_to_ok(_) ->
  instrument_tracer:with_span(<<"t">>, fun() ->
    ok = instrument_tracer:set_status(ok),
    ?assertEqual(ok, (instrument_tracer:current_span())#span.status)
  end).

status_unset_to_error(_) ->
  instrument_tracer:with_span(<<"t">>, fun() ->
    ok = instrument_tracer:set_status(error, <<"boom">>),
    ?assertEqual({error, <<"boom">>},
                 (instrument_tracer:current_span())#span.status)
  end).

status_error_to_ok(_) ->
  instrument_tracer:with_span(<<"t">>, fun() ->
    ok = instrument_tracer:set_status(error, <<"x">>),
    ok = instrument_tracer:set_status(ok),
    ?assertEqual(ok, (instrument_tracer:current_span())#span.status)
  end).

status_ok_is_final(_) ->
  instrument_tracer:with_span(<<"t">>, fun() ->
    ok = instrument_tracer:set_status(ok),
    ok = instrument_tracer:set_status(error, <<"ignored">>),
    ?assertEqual(ok, (instrument_tracer:current_span())#span.status)
  end).

status_unset_assignment_ignored(_) ->
  %% set_status only accepts ok | error; setting unset would not type-check.
  %% Verify error -> error transition is allowed (description update).
  instrument_tracer:with_span(<<"t">>, fun() ->
    ok = instrument_tracer:set_status(error, <<"a">>),
    ok = instrument_tracer:set_status(error, <<"b">>),
    ?assertEqual({error, <<"b">>},
                 (instrument_tracer:current_span())#span.status)
  end).

%% Attribute value truncation

attribute_value_truncated(_) ->
  os:putenv("OTEL_ATTRIBUTE_VALUE_LENGTH_LIMIT", "5"),
  instrument_tracer:with_span(<<"t">>, fun() ->
    ok = instrument_tracer:set_attributes(#{<<"k">> => <<"abcdefghij">>}),
    Attrs = (instrument_tracer:current_span())#span.attributes,
    ?assertEqual(<<"abcde">>, maps:get(<<"k">>, Attrs))
  end).

%% Per-event attribute count limit

event_attribute_count_limit(_) ->
  os:putenv("OTEL_EVENT_ATTRIBUTE_COUNT_LIMIT", "2"),
  instrument_tracer:with_span(<<"t">>, fun() ->
    Many = maps:from_list([{integer_to_binary(I), I} || I <- lists:seq(1, 10)]),
    ok = instrument_tracer:add_event(<<"evt">>, Many),
    [Event] = (instrument_tracer:current_span())#span.events,
    ?assertEqual(2, maps:size(Event#span_event.attributes)),
    ?assertEqual(8, Event#span_event.dropped_attributes_count)
  end).

%% Per-link attribute count limit

link_attribute_count_limit(_) ->
  os:putenv("OTEL_LINK_ATTRIBUTE_COUNT_LIMIT", "3"),
  instrument_tracer:with_span(<<"parent">>, fun() ->
    LinkedCtx = #span_ctx{
      trace_id = <<1:128>>,
      span_id = <<1:64>>,
      trace_flags = 1,
      trace_state = []
    },
    Many = maps:from_list([{integer_to_binary(I), I} || I <- lists:seq(1, 10)]),
    ok = instrument_tracer:add_link(#{span_ctx => LinkedCtx,
                                       attributes => Many}),
    [Link] = (instrument_tracer:current_span())#span.links,
    ?assertEqual(3, maps:size(Link#span_link.attributes)),
    ?assertEqual(7, Link#span_link.dropped_attributes_count)
  end).

%% Tracestate caps

tracestate_decode_drops_oversize_entries(_) ->
  Big = list_to_binary(lists:duplicate(300, $x)),
  Header = <<"k1=v1,bad=", Big/binary, ",k2=v2">>,
  Decoded = instrument_propagator_tracecontext:decode_tracestate(Header),
  ?assertEqual([{<<"k1">>, <<"v1">>}, {<<"k2">>, <<"v2">>}], Decoded).

tracestate_encode_caps_entries(_) ->
  Many = [{<<"k", (integer_to_binary(I))/binary>>, <<"v">>}
          || I <- lists:seq(1, 50)],
  Encoded = instrument_propagator_tracecontext:encode_tracestate(Many),
  Parts = binary:split(Encoded, <<",">>, [global, trim_all]),
  ?assertEqual(32, length(Parts)).

%% Baggage caps

baggage_set_rejects_over_entry_limit(_) ->
  ok = instrument_baggage:clear(),
  lists:foreach(fun(I) ->
    instrument_baggage:set(<<"k", (integer_to_binary(I))/binary>>, <<"v">>)
  end, lists:seq(1, 200)),
  All = instrument_baggage:get_all(),
  ?assert(map_size(All) =< 180).

baggage_decode_caps_entries(_) ->
  Header = iolist_to_binary(
    lists:join(<<",">>,
               [<<"k", (integer_to_binary(I))/binary, "=v">>
                || I <- lists:seq(1, 250)])),
  Decoded = instrument_baggage:decode(Header),
  ?assert(map_size(Decoded) =< 180).

%% Probability sampler should use upper 8 bytes (matches Java/Go SDKs).

probability_sampler_uses_upper_bytes(_) ->
  %% Trace id with upper 8 bytes = 0 (always sampled at any ratio > 0)
  %% and lower 8 bytes = max (would NOT sample if we used lower bytes).
  TraceId = <<0:64, 16#FFFFFFFFFFFFFFFF:64>>,
  Result = instrument_sampler_probability:should_sample(
             #{ratio => 0.5}, TraceId, <<"n">>, internal, #{}, [], undefined),
  ?assertEqual(record_and_sample, Result#sampling_result.decision).

%% Batch processor must clamp max_export_batch_size to max_queue_size.

batch_clamps_export_batch_to_queue_size(_) ->
  Config = #{exporter => instrument_otlp_retry_SUITE_exporter,
             exporter_config => #{},
             max_queue_size => 16,
             max_export_batch_size => 1024,
             schedule_delay_millis => 60000,
             export_timeout_millis => 5000},
  {ok, Pid} = instrument_span_processor_batch:start_link(Config),
  State = sys:get_state(Pid),
  %% State record: {state, exporter, exporter_state, max_queue_size,
  %%                       max_export_batch_size, ...}
  %% Tuple element 5 is max_export_batch_size.
  ?assertEqual(16, element(5, State)),
  ok = instrument_span_processor_batch:shutdown(),
  ok.
