%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Bad or unusual input must not crash writers, break a scrape, or grow
%% state without bound.
-module(instrument_safety_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).

-export([
  prometheus_names_are_sanitized/1,
  label_name_cannot_inject_lines/1,
  unusual_label_values_do_not_crash/1,
  repeated_create_does_not_grow_family_chain/1,
  vec_aliases_are_bounded_and_removed/1,
  invalid_histogram_boundaries_fail_at_create/1,
  non_numbers_are_rejected_before_any_update/1,
  registry_survives_unknown_call/1,
  unicode_log_keeps_handler/1,
  bad_header_names_are_skipped/1,
  trace_flags_round_trip/1,
  invalid_tracestate_keeps_traceparent/1,
  invalid_utf8_is_encoded/1,
  other_tracer_is_left_alone/1
]).

all() ->
  [prometheus_names_are_sanitized,
   label_name_cannot_inject_lines,
   unusual_label_values_do_not_crash,
   repeated_create_does_not_grow_family_chain,
   vec_aliases_are_bounded_and_removed,
   invalid_histogram_boundaries_fail_at_create,
   non_numbers_are_rejected_before_any_update,
   registry_survives_unknown_call,
   unicode_log_keeps_handler,
   bad_header_names_are_skipped,
   trace_flags_round_trip,
   invalid_tracestate_keeps_traceparent,
   invalid_utf8_is_encoded,
   other_tracer_is_left_alone].

init_per_suite(Config) ->
  _ = application:ensure_all_started(crypto),
  ok = application:start(instrument),
  Config.

end_per_suite(_Config) ->
  ok = application:stop(instrument).

meter() -> instrument_meter:get_meter(<<"safety">>).

%% OpenTelemetry-style dotted names render as valid Prometheus names.
prometheus_names_are_sanitized(_Config) ->
  C = instrument_meter:create_counter(meter(), <<"http.server.requests">>),
  ok = instrument_meter:add(C, 1, #{<<"http.request.method">> => <<"GET">>}),
  Out = instrument_prometheus:format(),
  ?assertNotEqual(nomatch,
    binary:match(Out, <<"http_server_requests_total{http_request_method=\"GET\"} 1">>)),
  ?assertEqual(nomatch, binary:match(Out, <<"http.server">>)),
  ok.

%% A label name taken from input cannot add lines to the output.
label_name_cannot_inject_lines(_Config) ->
  C = instrument_meter:create_counter(meter(), <<"inject_test">>),
  ok = instrument_meter:add(C, 1, #{<<"x=\"\"} 1\nfake_metric 999\n#">> => <<"v">>}),
  Out = instrument_prometheus:format(),
  ?assertEqual(nomatch, binary:match(Out, <<"\nfake_metric 999">>)),
  ok.

%% IP tuples, pids, non-Latin-1 strings and tuple keys are accepted.
unusual_label_values_do_not_crash(_Config) ->
  C = instrument_meter:create_counter(meter(), <<"unusual_values">>),
  ok = instrument_meter:add(C, 1, #{peer => {127, 0, 0, 1}}),
  ok = instrument_meter:add(C, 1, #{owner => self()}),
  ok = instrument_meter:add(C, 1, #{city => "東京"}),
  ok = instrument_meter:add(C, 1, #{{weird, key} => 1}),
  Out = instrument_prometheus:format(),
  ?assertNotEqual(nomatch, binary:match(Out, <<"peer=\"{127,0,0,1}\"">>)),
  ?assertNotEqual(nomatch, binary:match(Out, unicode:characters_to_binary("city=\"東京\""))),
  ok.

%% Calling new_counter/2 again for an existing metric reuses it.
repeated_create_does_not_grow_family_chain(_Config) ->
  _ = instrument_metric:new_counter(repeated_create, <<"h">>),
  Seq = persistent_term:get(instrument_family_seq),
  Before = atomics:get(Seq, 1),
  [instrument_metric:new_counter(repeated_create, <<"h">>) || _ <- lists:seq(1, 500)],
  ?assertEqual(Before, atomics:get(Seq, 1)),
  ok.

%% Raw label values that print alike share one series; their fast-path keys
%% are capped and removed with the series.
vec_aliases_are_bounded_and_removed(_Config) ->
  ok = instrument_metric:new_counter_vec(alias_vec, <<"h">>, [v]),
  ok = instrument_metric:inc_counter_vec(alias_vec, [1.0]),
  [ok = instrument_metric:inc_counter_vec(alias_vec, [1.0 + N * 1.0e-12])
   || N <- lists:seq(1, 5000)],
  Keys = [K || {{instrument_label, alias_vec, _} = K, _} <- persistent_term:get()],
  Limit = instrument_config:get_metric_cardinality_limit(),
  ?assert(length(Keys) =< Limit + 1),
  ?assertEqual(5001.0, instrument_metric:get_counter_vec(alias_vec, [1.0])),
  ?assertEqual(1, instrument_registry:label_count(alias_vec)),
  ok = instrument_metric:remove_label(alias_vec, [1.0 + 1.0e-12]),
  ?assertEqual(0, instrument_registry:label_count(alias_vec)),
  ?assertEqual([], [K || {{instrument_label, alias_vec, _} = K, _} <- persistent_term:get()]),
  ok.

invalid_histogram_boundaries_fail_at_create(_Config) ->
  ?assertError(empty_buckets,
    instrument_meter:create_histogram(meter(), <<"bad_hist_empty">>, #{boundaries => []})),
  ?assertError(bad_buckets,
    instrument_meter:create_histogram(meter(), <<"bad_hist_order">>, #{boundaries => [10, 5]})),
  ?assertError({bad_buckets, <<"a">>},
    instrument_meter:create_histogram(meter(), <<"bad_hist_type">>, #{boundaries => [<<"a">>]})),
  ok.

non_numbers_are_rejected_before_any_update(_Config) ->
  H = instrument_metric:new_histogram(nan_hist, <<"h">>),
  ?assertError(badarg, instrument_metric:observe_histogram(H, <<"x">>)),
  #{count := 0} = instrument_metric:get_histogram(H),
  C = instrument_metric:new_counter(nan_counter, <<"h">>),
  ?assertError(badarg, instrument_metric:inc_counter(C, <<"1">>)),
  ok.

registry_survives_unknown_call(_Config) ->
  Pid = whereis(instrument_registry),
  ?assertEqual({error, unknown_call}, gen_server:call(instrument_registry, nonsense)),
  gen_server:cast(instrument_registry, nonsense),
  _ = sys:get_state(instrument_registry),
  ?assertEqual(Pid, whereis(instrument_registry)),
  ok.

%% A log call whose output is not Latin-1 must not remove the handler.
unicode_log_keeps_handler(_Config) ->
  ok = instrument_logger:install(#{filter => false, exporter => true}),
  try
    logger:warning("user ~ts", [<<"日本"/utf8>>]),
    logger:warning("bad format ~p ~p", [only_one]),
    logger:warning("trace", #{trace_id => binary:copy(<<"z">>, 32)}),
    ?assertMatch({ok, _}, logger:get_handler_config(instrument_log_exporter_handler))
  after
    instrument_logger:uninstall()
  end.

%% Headers come from the network; unreadable ones are skipped.
bad_header_names_are_skipped(_Config) ->
  TP = <<"00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01">>,
  Ctx = instrument_propagation:extract_headers(
          [{<<"x-bad", 255>>, <<"v">>}, {[16#65E5], "v"}, not_a_pair,
           {<<"Traceparent">>, TP}]),
  ?assertMatch(#{span_ctx := _}, Ctx),
  ok.

%% Flags other than 00/01 (W3C level 2) are injected again, not dropped.
trace_flags_round_trip(_Config) ->
  TP = <<"00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-03">>,
  Ctx = instrument_propagation:extract(#{<<"traceparent">> => TP}),
  Out = instrument_propagation:inject(Ctx, #{}),
  ?assertEqual(TP, maps:get(<<"traceparent">>, Out)),
  ok.

invalid_tracestate_keeps_traceparent(_Config) ->
  TP = <<"00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01">>,
  Ctx = instrument_propagation:extract(#{<<"traceparent">> => TP,
                                         <<"tracestate">> => <<"a=", 255, ",b=ok">>}),
  ?assertMatch(#{span_ctx := _}, Ctx),
  ok.

%% Invalid UTF-8 in a value no longer makes JSON encoding raise.
invalid_utf8_is_encoded(_Config) ->
  Json = iolist_to_binary(instrument_lib:json_encode(#{<<"k">> => <<"a", 255, "b">>})),
  ?assertEqual(#{<<"k">> => <<"a", 16#EF, 16#BF, 16#BD, "b">>}, json:decode(Json)),
  ok.

%% A process traced by another tool keeps its tracer and flags.
other_tracer_is_left_alone(_Config) ->
  ok = instrument_flight_recorder:enable(),
  Tracer = spawn(fun Loop() -> receive _ -> Loop() end end),
  try
    1 = erlang:trace(self(), true, [send, {tracer, Tracer}]),
    instrument_tracer:with_span(<<"traced_elsewhere">>, fun() -> ok end),
    ?assertEqual({flags, [send]}, erlang:trace_info(self(), flags)),
    ?assertEqual({tracer, Tracer}, erlang:trace_info(self(), tracer))
  after
    erlang:trace(self(), false, [send]),
    exit(Tracer, kill),
    instrument_flight_recorder:disable()
  end.
