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
%%% == Storage ==
%%% A histogram with N user-defined boundaries plus an implicit +Inf bucket
%%% is backed by a single OTP `atomics' array of size N+2:
%%% <ul>
%%%   <li>slot 1 — IEEE-754 bit pattern of the running `sum' (float)</li>
%%%   <li>slots 2..N+2 — bucket counts (signed int64)</li>
%%% </ul>
%%% This eliminates per-bucket NIF resources and gives `observe_histogram'
%%% one cheap CAS-loop on the sum plus one `atomics:add' on the bucket.
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
  get_bucket_boundaries/1,
  collect/2,
  default_buckets/0,
  linear_buckets/3,
  exponential_buckets/3,
  validate_buckets/1,
  with_histogram/2, with_histogram/3,
  cleanup/1
]).

-include("instrument.hrl").

-define(DEFAULT_BUCKETS, [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]).
-define(SUM_SLOT, 1).
-define(BUCKET_SLOT_OFFSET, 1).  %% buckets start at slot 2

-record(histogram, {
  bucket_boundaries = [],
  atomics_ref,                          %% atomics ref, arity = N+2
  inf_slot :: pos_integer(),            %% slot index of the +Inf bucket
  start_time :: integer(),              %% wall clock time in nanoseconds when histogram was created
  exemplar_key :: reference() | undefined  %% Key for ETS-stored exemplar reservoir
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
  %% N boundaries + 1 (+Inf) bucket counts + 1 sum slot = N + 2 slots
  N = length(Buckets),
  Arity = N + 2,
  Ref = instrument_atomics:new(Arity),
  StartTime = erlang:system_time(nanosecond),
  ExemplarKey = instrument_exemplar:new_reservoir_ref(),

  #histogram{
    bucket_boundaries = Buckets,
    atomics_ref = Ref,
    inf_slot = Arity,
    start_time = StartTime,
    exemplar_key = ExemplarKey
  }.

validate_buckets([]) ->
  error_logger:error_msg("histogram buckets must not be empty", []),
  erlang:error(empty_buckets);
validate_buckets([Start | Rest]) ->
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
    atomics_ref = Ref,
    inf_slot = InfSlot,
    exemplar_key = ExemplarKey} = Hist,

  %% Find bucket slot. Boundaries map to slots 2..N+1; +Inf is the last slot.
  Slot = case find(Boundaries, Value, ?BUCKET_SLOT_OFFSET + 1) of
    -1 -> InfSlot;
    S -> S
  end,
  instrument_atomics:inc_int_at(Ref, Slot, 1),
  instrument_atomics:inc_at(Ref, ?SUM_SLOT, float(Value)),
  %% Capture exemplar with trace context
  case ExemplarKey of
    undefined -> ok;
    _ -> instrument_exemplar:offer_ref(ExemplarKey, Value, #{})
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
    atomics_ref = Ref,
    inf_slot = InfSlot
  } = Hist,
  SumValue = instrument_atomics:get_at(Ref, ?SUM_SLOT),
  CountsList = read_counts(Ref, ?BUCKET_SLOT_OFFSET + 1, InfSlot),
  SampleCount = lists:foldl(fun(Count, Acc) -> Acc + Count end, 0, CountsList),
  Buckets = cumulative_count(CountsList, Boundaries, 0, []),
  #{count => SampleCount,
    sum => SumValue,
    buckets => Buckets }.

%% @doc Get the bucket boundaries configured for this histogram.
-spec get_bucket_boundaries(#metric{}) -> [number()].
get_bucket_boundaries(#metric{handle = Hist}) ->
  Hist#histogram.bucket_boundaries.

read_counts(Ref, Slot, EndSlot) when Slot =< EndSlot ->
  [instrument_atomics:get_int_at(Ref, Slot) | read_counts(Ref, Slot + 1, EndSlot)];
read_counts(_Ref, _Slot, _EndSlot) ->
  [].

cumulative_count([Count | RestCounts], [Boundary | RestBoundaries], Acc, Buckets) ->
  Acc2 = Acc + Count,
  Bucket = #{cumulative_count => Acc2, upper_bound => Boundary, count => Count},
  cumulative_count(RestCounts, RestBoundaries, Acc2, [Bucket | Buckets]);
cumulative_count([InfCount], [], Acc, Buckets) ->
  %% +Inf bucket (values above all boundaries)
  Acc2 = Acc + InfCount,
  InfBucket = #{cumulative_count => Acc2, upper_bound => infinity, count => InfCount},
  lists:reverse([InfBucket | Buckets]);
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

%% @doc Release resources owned by this histogram metric (exemplar reservoir).
%% Tolerates non-histogram handles so callers can invoke this on any metric.
-spec cleanup(#metric{} | term()) -> ok.
cleanup(#metric{handle = Handle}) ->
  cleanup_handle(Handle);
cleanup(_) ->
  ok.

cleanup_handle(#histogram{exemplar_key = Key}) ->
  instrument_exemplar:delete_reservoir(Key);
cleanup_handle(_) ->
  ok.

collect(Info, Hist) ->
  #metric_info{name=Name, help=Help} = Info,
  #histogram{
    bucket_boundaries = Boundaries,
    atomics_ref = Ref,
    inf_slot = InfSlot,
    start_time = StartTime,
    exemplar_key = ExemplarKey
  } = Hist,
  SumValue = instrument_atomics:get_at(Ref, ?SUM_SLOT),
  CountsList = read_counts(Ref, ?BUCKET_SLOT_OFFSET + 1, InfSlot),
  SampleCount = lists:foldl(fun(Count, Acc) -> Acc + Count end, 0, CountsList),
  Buckets = cumulative_count(CountsList, Boundaries, 0, []),
  Exemplars = instrument_exemplar:collect_ref(ExemplarKey),

  %% Returns a histogram collection with all required fields for export.
  %% This format is compatible with Prometheus and OpenTelemetry metric exporters.
  #{name => Name,
    help => Help,
    type => histogram,
    count => SampleCount,
    sum => SumValue,
    buckets => Buckets,
    start_time => StartTime,
    exemplars => Exemplars}.
