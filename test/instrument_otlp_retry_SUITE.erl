%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.
-module(instrument_otlp_retry_SUITE).
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
  classify_http_5xx_as_retryable/1,
  classify_http_4xx_as_permanent/1,
  classify_429_as_retryable/1,
  classify_transport_errors/1,
  classify_unknown_as_permanent/1,
  batch_retries_on_retryable_then_succeeds/1,
  batch_drops_on_permanent/1,
  batch_gives_up_after_max_batch_retries/1
]).

-define(STUB, instrument_otlp_retry_SUITE_stub).

all() ->
  [
    classify_http_5xx_as_retryable,
    classify_http_4xx_as_permanent,
    classify_429_as_retryable,
    classify_transport_errors,
    classify_unknown_as_permanent,
    batch_retries_on_retryable_then_succeeds,
    batch_drops_on_permanent,
    batch_gives_up_after_max_batch_retries
  ].

init_per_suite(Config) ->
  Config.

end_per_suite(_Config) ->
  ok.

init_per_testcase(_TC, Config) ->
  reset_stub(),
  _ = catch instrument_span_processor_batch:shutdown(),
  Config.

end_per_testcase(_TC, _Config) ->
  _ = catch instrument_span_processor_batch:shutdown(),
  ok.

%% Classification tests

classify_http_5xx_as_retryable(_) ->
  ?assertEqual(retryable, instrument_otlp_retry:classify_error({http_error, 502, <<>>})),
  ?assertEqual(retryable, instrument_otlp_retry:classify_error({http_error, 503, <<>>})),
  ?assertEqual(retryable, instrument_otlp_retry:classify_error({http_error, 504, <<>>})),
  ok.

classify_http_4xx_as_permanent(_) ->
  ?assertEqual(permanent, instrument_otlp_retry:classify_error({http_error, 400, <<>>})),
  ?assertEqual(permanent, instrument_otlp_retry:classify_error({http_error, 401, <<>>})),
  ?assertEqual(permanent, instrument_otlp_retry:classify_error({http_error, 404, <<>>})),
  ?assertEqual(permanent, instrument_otlp_retry:classify_error({http_error, 501, <<>>})),
  ok.

classify_429_as_retryable(_) ->
  ?assertEqual(retryable, instrument_otlp_retry:classify_error({http_error, 429, <<>>})),
  ?assertEqual(retryable, instrument_otlp_retry:classify_error({http_error, 408, <<>>})),
  ok.

classify_transport_errors(_) ->
  ?assertEqual(retryable, instrument_otlp_retry:classify_error(timeout)),
  ?assertEqual(retryable, instrument_otlp_retry:classify_error(closed)),
  ?assertEqual(retryable, instrument_otlp_retry:classify_error(econnrefused)),
  ?assertEqual(retryable, instrument_otlp_retry:classify_error(nxdomain)),
  ok.

classify_unknown_as_permanent(_) ->
  ?assertEqual(permanent, instrument_otlp_retry:classify_error(no_such_error)),
  ?assertEqual(permanent, instrument_otlp_retry:classify_error({weird, thing})),
  ok.

%% Batch processor integration using a stub exporter.

batch_retries_on_retryable_then_succeeds(_) ->
  set_stub_responses([{error, retryable, dummy},
                      {error, retryable, dummy},
                      ok]),
  {ok, _} = start_batch(#{max_batch_retries => 5,
                          schedule_delay_millis => 60}),
  enqueue_stub_span(),
  wait_until(fun() -> stub_calls() >= 3 end, 3000),
  ?assertEqual(3, stub_calls()),
  ok.

batch_drops_on_permanent(_) ->
  set_stub_responses([{error, permanent, dummy}]),
  {ok, _} = start_batch(#{max_batch_retries => 5,
                          schedule_delay_millis => 60}),
  enqueue_stub_span(),
  wait_until(fun() -> stub_calls() >= 1 end, 1000),
  timer:sleep(300),
  ?assertEqual(1, stub_calls()),
  ok.

batch_gives_up_after_max_batch_retries(_) ->
  set_stub_responses(lists:duplicate(20, {error, retryable, dummy})),
  {ok, _} = start_batch(#{max_batch_retries => 3,
                          schedule_delay_millis => 40}),
  enqueue_stub_span(),
  wait_until(fun() -> stub_calls() >= 3 end, 2000),
  timer:sleep(300),
  ?assertEqual(3, stub_calls()),
  ok.

%% -------- helpers --------

start_batch(Overrides) ->
  Config = maps:merge(#{exporter => instrument_otlp_retry_SUITE_exporter,
                        exporter_config => #{},
                        max_queue_size => 1024,
                        max_export_batch_size => 1024,
                        schedule_delay_millis => 100,
                        export_timeout_millis => 2000},
                      Overrides),
  instrument_span_processor_batch:start_link(Config).

enqueue_stub_span() ->
  gen_server:cast(instrument_span_processor_batch,
                  {on_end, {stub_span, make_ref()}}),
  ok.

wait_until(Pred, Timeout) ->
  Deadline = erlang:monotonic_time(millisecond) + Timeout,
  wait_until_loop(Pred, Deadline).

wait_until_loop(Pred, Deadline) ->
  case Pred() of
    true -> ok;
    false ->
      case erlang:monotonic_time(millisecond) > Deadline of
        true -> timeout;
        false ->
          timer:sleep(20),
          wait_until_loop(Pred, Deadline)
      end
  end.

reset_stub() ->
  case ets:whereis(?STUB) of
    undefined ->
      ets:new(?STUB, [public, named_table, set, {write_concurrency, true}]);
    _ -> ok
  end,
  ets:insert(?STUB, {responses, []}),
  ets:insert(?STUB, {calls, 0}),
  ok.

set_stub_responses(Responses) ->
  reset_stub(),
  ets:insert(?STUB, {responses, Responses}),
  ok.

stub_calls() ->
  case ets:lookup(?STUB, calls) of
    [{calls, N}] -> N;
    [] -> 0
  end.
