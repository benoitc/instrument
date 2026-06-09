-module(instrument_otlp_histogram_SUITE).
-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([histogram_batch_encodes_test/1]).
-export([histogram_bucket_counts_per_bucket_test/1]).
-include_lib("stdlib/include/assert.hrl").

all() -> [histogram_batch_encodes_test, histogram_bucket_counts_per_bucket_test].

init_per_suite(Config) ->
  _ = application:ensure_all_started(crypto),
  ok = application:start(instrument),
  Config.

end_per_suite(Config) ->
  ok = application:stop(instrument),
  Config.

%% A synthetic converted histogram data point: cumulative counts under `bound`,
%% with the +Inf bucket last (this is what convert_metric/2 produces).
hist_metric(Name) ->
  DP = #{attributes => #{}, timestamp => 123,
         value => #{count => 8, sum => 42.0,
                    buckets => [#{bound => 1, count => 2},
                                #{bound => 5, count => 5},
                                #{bound => 10, count => 7},
                                #{bound => infinity, count => 8}]}},
  #{name => Name, type => histogram, data_points => [DP]}.

%% Pull every metric object out of a decoded OTLP payload.
all_metrics(Decoded) ->
  RMs = maps:get(<<"resourceMetrics">>, Decoded),
  lists:append([maps:get(<<"metrics">>, SM)
                || RM <- RMs, SM <- maps:get(<<"scopeMetrics">>, RM)]).

decode(Json) ->
  json:decode(iolist_to_binary(Json)).

%% Crash regression: a batch with a histogram AND a counter must encode.
%% Today the histogram raises {badkey, upper_bound} and the whole batch is lost.
histogram_batch_encodes_test(_Config) ->
  Counter = #{name => <<"c_otlp">>, type => counter,
              data_points => [#{attributes => #{}, value => 5, timestamp => 1}]},
  Json = instrument_metrics_exporter_otlp:encode_metrics([Counter, hist_metric(<<"h_otlp">>)]),
  Names = [maps:get(<<"name">>, M) || M <- all_metrics(decode(Json))],
  ?assert(lists:member(<<"c_otlp">>, Names)),
  ?assert(lists:member(<<"h_otlp">>, Names)),
  ok.

%% bucketCounts must be PER-BUCKET deltas, not cumulative. explicitBounds
%% excludes +Inf and is exactly one shorter than bucketCounts.
histogram_bucket_counts_per_bucket_test(_Config) ->
  Json = instrument_metrics_exporter_otlp:encode_metrics([hist_metric(<<"h_otlp">>)]),
  [Hist] = [M || M <- all_metrics(decode(Json)), maps:get(<<"name">>, M) =:= <<"h_otlp">>],
  [DP] = maps:get(<<"dataPoints">>, maps:get(<<"histogram">>, Hist)),
  %% cumulative [2,5,7,8] -> per-bucket [2,3,2,1]; counts are encoded as strings
  ?assertEqual([<<"2">>, <<"3">>, <<"2">>, <<"1">>], maps:get(<<"bucketCounts">>, DP)),
  ?assertEqual([1, 5, 10], maps:get(<<"explicitBounds">>, DP)),
  ?assertEqual(4, length(maps:get(<<"bucketCounts">>, DP))),
  ?assertEqual(3, length(maps:get(<<"explicitBounds">>, DP))),
  ok.
