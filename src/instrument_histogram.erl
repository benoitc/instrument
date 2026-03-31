%%%-------------------------------------------------------------------
%%% @author benoitc
%%% @copyright (C) 2017-2026, Benoit Chesneau
%%% @doc Histogram metric for measuring distributions of values.
%%%
%%% A histogram samples observations (usually things like request durations
%%% or response sizes) and counts them in configurable buckets. It also
%%% provides a sum of all observed values and a count of observations.
%%%
%%% == Bucket Configuration ==
%%% Histograms use upper-bound exclusive buckets. Values are counted in the
%%% first bucket where `value <= boundary'. Default buckets follow Prometheus
%%% conventions: `[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]'
%%%
%%% Custom buckets can be created with:
%%% <ul>
%%%   <li>`default_buckets/0' - Standard Prometheus buckets</li>
%%%   <li>`linear_buckets/3' - Evenly spaced buckets</li>
%%%   <li>`exponential_buckets/3' - Exponentially growing buckets</li>
%%% </ul>
%%%
%%% == Example ==
%%% ```
%%% %% Create histogram with default buckets
%%% Hist = instrument_histogram:new_histogram(latency, <<"Request latency">>),
%%%
%%% %% Create histogram with custom buckets
%%% Buckets = instrument_histogram:linear_buckets(0.1, 0.1, 10),
%%% Hist2 = instrument_histogram:new_histogram(size, <<"Response size">>, Buckets),
%%%
%%% %% Record observations
%%% instrument_histogram:observe_histogram(Hist, 0.042),
%%% instrument_histogram:observe_histogram(Hist, 0.156).
%%% '''
%%% @end
%%% Created : 28. Apr 2017 21:15
%%%-------------------------------------------------------------------
-module(instrument_histogram).
-author("benoitc").

%% API
-export([
  new_histogram/2, new_histogram/3,
  observe_histogram/2,
  get_histogram/1,
  collect/2,
  default_buckets/0,
  linear_buckets/3,
  exponential_buckets/3,
  validate_buckets/1,
  with_histogram/2, with_histogram/3
]).

-include("instrument.hrl").

-define(DEFAULT_BUCKETS, [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]).

-record(histogram, {
  bucket_boundaries = [],
  bucket_counts = [],
  sum = 0.0
}).

new_histogram(Name, Help) -> new_histogram(Name, Help, ?DEFAULT_BUCKETS).

new_histogram(Name, Help, Buckets) ->
  Info = instrument_lib:mk_info(Name, Help),
  Hist = mk_histogram(Buckets),
  #metric{
    name = Name,
    handle = Hist,
    collect = {?MODULE, collect, [Info, Hist]}
  }.

mk_histogram(Buckets) ->
  ok = validate_buckets(Buckets),
  Counts = lists:map(
    fun(_) ->
      {ok, Ref} = instrument_nif:new_gauge(),
      Ref
    end, Buckets),
  {ok, Sum} =  instrument_nif:new_gauge(),
  
  #histogram{
    bucket_boundaries = Buckets,
    bucket_counts = list_to_tuple(Counts),
    sum = Sum
  }.

validate_buckets(Buckets) ->
  [Start | Rest] = Buckets,
  validate_buckets(Rest, Start).

validate_buckets([Boundary | Rest], Prev) when Boundary > Prev ->
  validate_buckets(Rest, Boundary);
validate_buckets([Boundary | _], Prev) ->
  error_logger:error_msg(
    "histogram buckets must be in increasing order: ~p >= ~p",
    [Boundary, Prev]
  ),
  erlang:error(bad_buckets);
validate_buckets([], _) ->
  ok.

observe_histogram(#metric{handle=Hist}, Value) ->
  #histogram{bucket_boundaries = Boundaries,
    bucket_counts = Counts,
    sum = Sum} = Hist,
  
  case find(Boundaries, Value, 1) of
    Idx when Idx > 0 ->
      instrument_nif:inc_gauge(element(Idx, Counts)),
      instrument_nif:inc_gauge(Sum, float(Value));
    _ ->
      ok
  end.

%% Linear search is efficient for typical histogram bucket counts (10-15 buckets).
%% For the default OTel bucket configuration, linear search outperforms binary
%% search due to lower overhead. Binary search only provides benefit at ~30+ buckets.
find([Boundary | _], Value, I) when Boundary >= Value -> I;
find([_ | Rest], Value, I) -> find(Rest, Value, I + 1);
find([], _Value, _I) -> -1.


get_histogram(#metric{handle=Hist}) ->
  #histogram{
    bucket_boundaries = Boundaries,
    bucket_counts = Counts,
    sum = Sum
  } = Hist,
  SumValue = instrument_nif:get_gauge(Sum),
  CountsList = [instrument_nif:get_gauge(C) || C <- tuple_to_list(Counts)],
  SampleCount = lists:foldl(fun(Count, Acc) ->  Acc + Count end, 0, CountsList),
  Buckets = cumulative_count(CountsList, Boundaries, 0.0, []),
  #{count => SampleCount,
    sum => SumValue,
    buckets => Buckets }.


cumulative_count([Count | RestCounts], [Boundary | RestBoundaries], Acc, Buckets) ->
  Acc2 = Acc + Count,
  Bucket = #{cumulative_count => Acc2, upper_bound => Boundary},
  cumulative_count(RestCounts, RestBoundaries, Acc2, [Bucket | Buckets]);
cumulative_count([], [], _Acc, Buckets) ->
  lists:reverse(Buckets).

default_buckets() ->
  ?DEFAULT_BUCKETS.

linear_buckets(Start, Width, Count) when Count > 1->
  {_, Buckets} = lists:foldl(
    fun(_I, {Acc, Buckets1}) ->
      Buckets2 = [Acc | Buckets1],
      Acc2 = Acc + Width,
      {Acc2, Buckets2}
    end, {Start, []}, lists:seq(1, Count)),
  lists:reverse(Buckets).


exponential_buckets(Start, Factor, Count) when Count > 1, Start > 0, Factor > 1 ->
  {_, Buckets} = lists:foldl(
    fun(_I, {Acc, Buckets1}) ->
      Buckets2 = [Acc | Buckets1],
      Acc2 = Acc * Factor,
      {Acc2, Buckets2}
    end, {Start, []}, lists:seq(1, Count)),
  lists:reverse(Buckets).

with_histogram(Hist, F) -> with_histogram_1(Hist, F, []).
with_histogram(Hist, F, V) -> with_histogram_1(Hist, F, [V]).
with_histogram_1(Hist, F, A) ->
  instrument_registry:with(Hist, fun(M) -> erlang:apply(?MODULE, F, [M|A]) end).

collect(Info, Hist) ->
  #metric_info{name=Name, help=Help} = Info,
  #histogram{
    bucket_boundaries = Boundaries,
    bucket_counts = Counts,
    sum = Sum
  } = Hist,
  SumValue = instrument_nif:get_gauge(Sum),
  CountsList = [instrument_nif:get_gauge(C) || C <- tuple_to_list(Counts)],
  SampleCount = lists:foldl(fun(Count, Acc) ->  Acc + Count end, 0, CountsList),
  Buckets = cumulative_count(CountsList, Boundaries, 0.0, []),
  
  %% Returns a complete histogram collection with all required fields for export.
  %% This format is compatible with Prometheus and OpenTelemetry metric exporters.
  #{name => Name,
    help => Help,
    type => histogram,
    count => SampleCount,
    sum => SumValue,
    buckets => Buckets}.
    