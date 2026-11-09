%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Bad or unusual input must not crash writers, break a scrape, or grow
%% state without bound.
-module(instrument_safety_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("instrument_otel.hrl").

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
  other_tracer_is_left_alone/1,
  otlp_response_size_is_capped/1,
  oversized_propagation_headers_are_ignored/1,
  text_logs_cannot_forge_lines/1,
  unlabeled_fast_path_follows_series_lifecycle/1
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
   other_tracer_is_left_alone,
   otlp_response_size_is_capped,
   oversized_propagation_headers_are_ignored,
   text_logs_cannot_forge_lines,
   unlabeled_fast_path_follows_series_lifecycle].

init_per_suite(Config) ->
  _ = application:ensure_all_started(crypto),
  {ok, _} = application:ensure_all_started(instrument),
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
  PtBefore = length(persistent_term:get()),
  [ok = instrument_metric:inc_counter_vec(alias_vec, [1.0 + N * 1.0e-12])
   || N <- lists:seq(1, 5000)],
  %% aliases add no persistent_term keys, and at most Limit ETS keys
  ?assertEqual(PtBefore, length(persistent_term:get())),
  Inc = alias_inc(),
  Limit = instrument_config:get_metric_cardinality_limit(),
  ?assert(length(alias_rows(Inc)) =< Limit + 1),
  Cached = [K || {{'$instrument_series', alias_vec, _} = K, _} <- get()],
  ?assert(length(Cached) =< Limit + 1),
  ?assertEqual(5001.0, instrument_metric:get_counter_vec(alias_vec, [1.0])),
  ?assertEqual(1, instrument_registry:label_count(alias_vec)),
  ok = instrument_metric:remove_label(alias_vec, [1.0 + 1.0e-12]),
  ?assertEqual(0, instrument_registry:label_count(alias_vec)),
  ?assertEqual([], alias_rows(Inc)),
  ok.

alias_inc() ->
  {family, _, _, _, _, _, _, Inc, _, _} = instrument_series:family(alias_vec),
  Inc.

alias_rows(Inc) ->
  ets:select(instrument_series, [{{{'$s', Inc, key, '_'}, '_', '_'}, [], ['$_']}]).

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

%% A collector answering with a huge body is cut off at the size limit and
%% the export is not retried; a normal answer still succeeds.
otlp_response_size_is_capped(_Config) ->
  {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
  {ok, Port} = inet:port(Listen),
  Requests = atomics:new(1, []),
  Server = spawn_link(fun() -> serve(Listen, Requests) end),
  try
    Url = iolist_to_binary(["http://127.0.0.1:", integer_to_list(Port), "/big"]),
    ?assertEqual({error, permanent, body_too_large},
                 instrument_otlp_retry:send_with_retry(post, Url, [], <<"x">>,
                                                       [{recv_timeout, 5000}],
                                                       #{max_retries => 3})),
    ?assertEqual(1, atomics:get(Requests, 1)),
    Small = iolist_to_binary(["http://127.0.0.1:", integer_to_list(Port), "/small"]),
    ?assertEqual(ok, instrument_otlp_retry:send_with_retry(post, Small, [], <<"x">>,
                                                          [{recv_timeout, 5000}]))
  after
    unlink(Server),
    exit(Server, kill),
    gen_tcp:close(Listen)
  end.

serve(Listen, Requests) ->
  {ok, Sock} = gen_tcp:accept(Listen),
  {ok, Req} = read_request(Sock, <<>>),
  atomics:add(Requests, 1, 1),
  Body = case binary:match(Req, <<"/big">>) of
           nomatch -> <<"{}">>;
           _ -> binary:copy(<<"x">>, 1024 * 1024)
         end,
  gen_tcp:send(Sock, [<<"HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: ">>,
                      integer_to_binary(byte_size(Body)), <<"\r\n\r\n">>, Body]),
  gen_tcp:close(Sock),
  serve(Listen, Requests).

read_request(Sock, Acc) ->
  case binary:match(Acc, <<"\r\n\r\n">>) of
    nomatch ->
      {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
      read_request(Sock, <<Acc/binary, Data/binary>>);
    _ ->
      {ok, Acc}
  end.

%% Oversized propagation headers are ignored without being parsed in full.
oversized_propagation_headers_are_ignored(_Config) ->
  TP = <<"00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01">>,
  Huge = binary:copy(<<"k=v,">>, 256 * 1024),
  {Time, Ctx} = timer:tc(fun() ->
    instrument_propagation:extract(#{<<"traceparent">> => TP, <<"tracestate">> => Huge,
                                     <<"baggage">> => Huge})
  end),
  %% traceparent kept, oversized tracestate ignored
  #{span_ctx := SpanCtx} = Ctx,
  ?assertEqual([], SpanCtx#span_ctx.trace_state),
  %% baggage keeps at most the first entries within the W3C limits
  ?assert(map_size(instrument_baggage:decode(Huge)) =< 180),
  ?assert(Time < 1000000),
  %% too long to be a traceparent or a b3 header
  ?assertEqual(error, maps:find(span_ctx, instrument_propagation:extract(
    #{<<"traceparent">> => <<TP/binary, (binary:copy(<<"-x">>, 300))/binary>>}))),
  ?assertEqual(error, maps:find(span_ctx, instrument_propagator_b3:extract(
    #{<<"b3">> => <<"0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-1-",
                    (binary:copy(<<"0">>, 200))/binary>>}, #{}))),
  ok.

%% A text log body containing a newline stays on one line.
text_logs_cannot_forge_lines(Config) ->
  Dir = proplists:get_value(priv_dir, Config),
  Path = filename:join(Dir, "forge.log"),
  Record = #log_record{timestamp = erlang:system_time(nanosecond),
                       observed_timestamp = erlang:system_time(nanosecond),
                       severity_number = 9, severity_text = <<"INFO">>,
                       body = <<"ok\nERROR fake entry\r\n">>, attributes = #{}},
  {ok, S0} = instrument_log_exporter_file:exporter_init(#{path => list_to_binary(Path),
                                                          format => text}),
  {ok, S1} = instrument_log_exporter_file:exporter_export([Record], S0),
  ok = instrument_log_exporter_file:exporter_shutdown(S1),
  {ok, Data} = file:read_file(Path),
  ?assertEqual(1, length(binary:split(Data, <<"\n">>, [global, trim_all]))),
  ?assertNotEqual(nomatch, binary:match(Data, <<"ok\\nERROR fake entry\\r\\n">>)),
  ConsolePath = filename:join(Dir, "forge_console.log"),
  {ok, Dev} = file:open(ConsolePath, [write]),
  {ok, C0} = instrument_log_exporter_console:exporter_init(#{format => text, output => Dev}),
  {ok, _} = instrument_log_exporter_console:exporter_export([Record], C0),
  ok = file:close(Dev),
  {ok, ConsoleData} = file:read_file(ConsolePath),
  ?assertEqual(1, length(binary:split(ConsoleData, <<"\n">>, [global, trim_all]))),
  ok.

%% Unlabeled writes go straight to the instrument's cell, but only while its
%% series is live: no series before the first write, writes after clear revive
%% it, and a descriptor held across unregister/re-create reaches the new metric.
unlabeled_fast_path_follows_series_lifecycle(_Config) ->
  M = meter(),
  C = instrument_meter:create_counter(M, <<"fast_unlabeled">>),
  Out0 = instrument_prometheus:format(),
  ?assertEqual(nomatch, binary:match(Out0, <<"fast_unlabeled_total ">>)),
  ok = instrument_meter:add(C, 2),
  ok = instrument_meter:add(C, 3),
  ?assertNotEqual(nomatch, binary:match(instrument_prometheus:format(), <<"fast_unlabeled_total 5">>)),
  ok = instrument_registry:clear_labels({otel, <<"fast_unlabeled">>}),
  ?assertEqual(nomatch, binary:match(instrument_prometheus:format(), <<"fast_unlabeled_total ">>)),
  ok = instrument_meter:add(C, 1),
  ?assertNotEqual(nomatch, binary:match(instrument_prometheus:format(), <<"fast_unlabeled_total 1">>)),
  ok = instrument_meter:unregister_instrument(<<"fast_unlabeled">>),
  _ = instrument_meter:create_counter(M, <<"fast_unlabeled">>),
  ok = instrument_meter:add(C, 7),
  ?assertNotEqual(nomatch, binary:match(instrument_prometheus:format(), <<"fast_unlabeled_total 7">>)),
  ok.
