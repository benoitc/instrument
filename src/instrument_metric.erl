%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Main API facade for metrics instrumentation.
%%
%% This module provides a unified interface for creating and manipulating
%% metrics including counters, gauges, and histograms. It supports both
%% simple metrics and vector metrics (metrics with labels).
%%
%% == Simple Metrics ==
%% ```
%% Counter = instrument:new_counter(requests_total, <<"Total HTTP requests">>),
%% instrument:inc_counter(Counter),
%% instrument:inc_counter(Counter, 5).
%% '''
%%
%% == Vector Metrics (Labeled) ==
%% ```
%% instrument:new_counter_vec(http_requests, <<"Requests">>, [method, status]),
%% instrument:inc_counter_vec(http_requests, [<<"GET">>, <<"200">>]).
%% '''
%%
%% For OpenTelemetry-compatible metrics, see {@link instrument_meter}.
-module(instrument_metric).
-author("benoitc").

%% COUNTER API
-export([
  new_counter/2,
  inc_counter/1, inc_counter/2,
  get_counter/1
]).

%% GAUGE API
-export([
  new_gauge/2,
  inc_gauge/1, inc_gauge/2,
  dec_gauge/1, dec_gauge/2,
  set_gauge/2,
  set_gauge_to_current_time/1,
  get_gauge/1
]).

%% HISTOGRAM API
-export([
  new_histogram/2, new_histogram/3,
  observe_histogram/2,
  get_histogram/1
]).

%% VECTOR API (legacy)
-export([
  new_vector/4, new_vector/5,
  get_vector_with/2,
  with_label/3, with_label/4,
  remove_label/2,
  clear_labels/1
]).

%% VEC API (prometheus-cpp style)
-export([
  new_counter_vec/3,
  new_gauge_vec/3,
  new_histogram_vec/3, new_histogram_vec/4,
  labels/2
]).

%% Vec operations by name + labels
-export([
  inc_counter_vec/2, inc_counter_vec/3,
  get_counter_vec/2,
  inc_gauge_vec/2, inc_gauge_vec/3,
  dec_gauge_vec/2, dec_gauge_vec/3,
  set_gauge_vec/3,
  get_gauge_vec/2,
  observe_histogram_vec/3,
  get_histogram_vec/2
]).

%% REGISTRY API

-export([
  register/1,
  unregister/1,
  unregister_all/0
]).


-include("instrument.hrl").

-type metric() :: #metric{} | atom().
-type metric_name() :: string() | atom() | binary().
-type help() :: string() | binary().
-type metric_type() :: gauge | counter | histogram.

-type label() :: string() | atom() | binary().
-type labels() :: [label()].
-type label_value() :: [label()] | #{}.


-export_type([
  metric/0,
  metric_name/0,
  help/0,
  metric_type/0,
  label/0,
  labels/0
]).


%% COUNTER

-spec new_counter(Name :: metric_name(), Help :: help()) -> Counter :: metric().
new_counter(Name, Help) ->
  _ = instrument_series:ensure_family(Name, counter, to_help(Help), undefined, undefined),
  Canon = {[], []},
  _ = instrument_series:write(Name, Canon, fun() -> Canon end, fun(_R) -> ok end),
  Row = unlabeled_row(Name, Canon),
  Row#metric{name = Name}.

-spec inc_counter(Counter :: metric()) -> Result :: ok | {error, not_found}.
inc_counter(Counter) ->
  instrument_counter:with_counter(Counter, inc_counter).


-spec inc_counter(Counter :: metric(), Value :: number()) -> Result :: ok | {error, not_found}.
inc_counter(Counter, Value) ->
  instrument_counter:with_counter(Counter, inc_counter, Value).

-spec get_counter(Counter :: metric()) -> Result :: float() | {error, not_found}.
get_counter(Counter) ->
  instrument_counter:with_counter(Counter, get_counter).


%% GAUGE

-spec new_gauge(Name :: metric_name(), Help :: help()) -> Gauge :: metric().
new_gauge(Name, Help) ->
  _ = instrument_series:ensure_family(Name, gauge, to_help(Help), undefined, undefined),
  Canon = {[], []},
  _ = instrument_series:write(Name, Canon, fun() -> Canon end, fun(_R) -> ok end),
  Row = unlabeled_row(Name, Canon),
  Row#metric{name = Name}.

-spec inc_gauge(Gauge :: metric()) -> Result :: ok | {error, not_found}.
inc_gauge(Gauge) ->
  instrument_gauge:with_gauge(Gauge, inc_gauge).

-spec inc_gauge(Gauge :: metric(), Value :: number()) -> Result :: ok | {error, not_found}.
inc_gauge(Gauge, Value) ->
  instrument_gauge:with_gauge(Gauge, inc_gauge, Value).

-spec dec_gauge(Gauge :: metric()) -> Result :: ok | {error, not_found}.
dec_gauge(Gauge) ->
  instrument_gauge:with_gauge(Gauge, dec_gauge).


-spec dec_gauge(Gauge :: metric(), Value :: number()) -> Result :: ok | {error, not_found}.
dec_gauge(Gauge, Value) ->
  instrument_gauge:with_gauge(Gauge, dec_gauge, Value).

-spec set_gauge(Gauge :: metric(), Value :: number()) -> Result :: ok | {error, not_found}.
set_gauge(Gauge, Value) ->
  instrument_gauge:with_gauge(Gauge, set_gauge, Value).

-spec set_gauge_to_current_time(Gauge :: metric()) -> Result :: ok | {error, not_found}.
set_gauge_to_current_time(Gauge) ->
  Time = erlang:monotonic_time(second),
  set_gauge(Gauge, Time).


-spec get_gauge(Gauge :: metric()) -> Result :: float() | {error, not_found}.
get_gauge(Gauge) ->
  instrument_gauge:with_gauge(Gauge, get_gauge).

%% HISTOGRAM

-spec new_histogram(Name :: metric_name(), Help :: help()) -> Hist::metric().
new_histogram(Name, Help) ->
  new_histogram(Name, Help, instrument_histogram:default_buckets()).

-spec new_histogram(Name :: metric_name(), Help :: help(), Buckets::list()) -> Hist::metric().
new_histogram(Name, Help, Buckets) ->
  %% validate_buckets raises before family registration on bad input, preserving
  %% master's error behavior
  ok = instrument_histogram:validate_buckets(Buckets),
  _ = instrument_series:ensure_family(Name, histogram, to_help(Help), undefined, Buckets),
  Canon = {[], []},
  _ = instrument_series:write(Name, Canon, fun() -> Canon end, fun(_R) -> ok end),
  Row = unlabeled_row(Name, Canon),
  Row#metric{name = Name}.

-spec observe_histogram(Hist::metric(), Value::number()) -> ok | {error, not_found}.
observe_histogram(Hist, Value) ->
  instrument_histogram:with_histogram(Hist, observe_histogram, Value).

-spec get_histogram(Hist :: metric()) -> Value :: term().
get_histogram(Hist) ->
  instrument_histogram:with_histogram(Hist, get_histogram).

%% VECTOR

-spec new_vector(
    Labels::labels(), MetricType :: metric_type(), Name :: metric_name(), Help :: help()
) -> Vector :: metric().
new_vector(Labels, MetricType, Name, Help) ->
  instrument_vector:new(Labels, MetricType, Name, Help).

-spec new_vector(
    Labels::labels(), MetricType :: metric_type(), Name :: metric_name(), Help :: help(), Buckets :: list()
) -> Vector :: metric().
new_vector(Labels, MetricType, Name, Help, Buckets) ->
  instrument_vector:new(Labels, MetricType, Name, Help, Buckets).

-spec with_label(Vector :: metric(), Label :: label_value(), Fun :: mfa()) -> Result :: term().
with_label(Vector, Label, Fun) ->
  instrument_vector:with_label(Vector, Label, Fun).

-spec with_label(
    Vector :: metric(), Label :: label_value(), Fun :: mfa(), Val :: number()
) -> Result :: term().
with_label(Vector, Label, Fun, V) ->
  instrument_vector:with_label(Vector, Label, Fun, V).

-spec get_vector_with(Vector :: metric(), Fun :: mfa()) -> Result :: term().
get_vector_with(Vector, Fun) ->
  instrument_vector:with(Vector, Fun).

-spec remove_label(Vector :: metric(), Label :: label_value()) -> Result :: term().
remove_label(Vector, Label) ->
  instrument_vector:remove_label(Vector, Label).

-spec clear_labels(Vector :: metric()) -> ok.
clear_labels(Vector) ->
  instrument_vector:clear_labels(Vector).


%% REGISTRY API

register(Metric) ->
  instrument_registry:register(Metric).

%% Resolve the unlabeled row for a simple (no-label) metric after a write/4
%% call.  The winner publishes to persistent_term itself; a claim loser racing
%% that publication falls back to the arbiter row in the ETS series table, which
%% exists from the instant the claim succeeded and carries the row payload.
-spec unlabeled_row(metric_name(), {[], []}) -> #metric{}.
unlabeled_row(Name, Canon) ->
  case persistent_term:get({instrument_label, Name, Canon}, undefined) of
    #metric{} = R -> R;
    undefined ->
      %% claim loser racing the winner's pt publication: the arbiter row is
      %% authoritative from the moment the claim landed
      ets:lookup_element(instrument_series, {Name, Canon}, 2)
  end.

to_help(Help) when is_binary(Help) -> Help;
to_help(Help) when is_list(Help) ->
  %% Accept flat string() or binary iolist; for other list terms (e.g. proplists
  %% passed by tests), fall back to a term-formatted binary.
  try iolist_to_binary(Help)
  catch error:badarg ->
    iolist_to_binary(io_lib:format("~p", [Help]))
  end;
to_help(Help) ->
  iolist_to_binary(io_lib:format("~p", [Help])).

unregister(Name) ->
  instrument_registry:unregister(Name).

unregister_all() ->
  instrument_registry:unregister_all().


%% VEC API (prometheus-cpp style)

-spec new_counter_vec(Name :: metric_name(), Help :: help(), Labels :: labels()) -> ok.
new_counter_vec(Name, Help, Labels) ->
  _ = instrument_vector:new(Labels, counter, Name, Help),
  ok.

-spec new_gauge_vec(Name :: metric_name(), Help :: help(), Labels :: labels()) -> ok.
new_gauge_vec(Name, Help, Labels) ->
  _ = instrument_vector:new(Labels, gauge, Name, Help),
  ok.

-spec new_histogram_vec(Name :: metric_name(), Help :: help(), Labels :: labels()) -> ok.
new_histogram_vec(Name, Help, Labels) ->
  _ = instrument_vector:new(Labels, histogram, Name, Help),
  ok.

-spec new_histogram_vec(Name :: metric_name(), Help :: help(), Labels :: labels(), Buckets :: list()) -> ok.
new_histogram_vec(Name, Help, Labels, Buckets) ->
  _ = instrument_vector:new(Labels, histogram, Name, Help, Buckets),
  ok.

-spec labels(Name :: metric_name(), LabelValues :: list()) -> metric() | {error, term()}.
labels(Name, LabelValues) ->
  case instrument_vector:get_or_create_label(Name, LabelValues) of
    {ok, Metric} -> Metric;
    Error -> Error
  end.

%% Vec operations by name + labels

-spec inc_counter_vec(Name :: metric_name(), LabelValues :: list()) -> ok | {error, term()}.
inc_counter_vec(Name, LabelValues) ->
  with_labeled_metric(Name, LabelValues, fun instrument_counter:inc_counter/1).

-spec inc_counter_vec(Name :: metric_name(), LabelValues :: list(), Value :: number()) -> ok | {error, term()}.
inc_counter_vec(Name, LabelValues, Value) ->
  with_labeled_metric(Name, LabelValues, fun(M) -> instrument_counter:inc_counter(M, Value) end).

-spec get_counter_vec(Name :: metric_name(), LabelValues :: list()) -> float() | {error, term()}.
get_counter_vec(Name, LabelValues) ->
  with_labeled_metric(Name, LabelValues, fun instrument_counter:get_counter/1).

-spec inc_gauge_vec(Name :: metric_name(), LabelValues :: list()) -> ok | {error, term()}.
inc_gauge_vec(Name, LabelValues) ->
  with_labeled_metric(Name, LabelValues, fun instrument_gauge:inc_gauge/1).

-spec inc_gauge_vec(Name :: metric_name(), LabelValues :: list(), Value :: number()) -> ok | {error, term()}.
inc_gauge_vec(Name, LabelValues, Value) ->
  with_labeled_metric(Name, LabelValues, fun(M) -> instrument_gauge:inc_gauge(M, Value) end).

-spec dec_gauge_vec(Name :: metric_name(), LabelValues :: list()) -> ok | {error, term()}.
dec_gauge_vec(Name, LabelValues) ->
  with_labeled_metric(Name, LabelValues, fun instrument_gauge:dec_gauge/1).

-spec dec_gauge_vec(Name :: metric_name(), LabelValues :: list(), Value :: number()) -> ok | {error, term()}.
dec_gauge_vec(Name, LabelValues, Value) ->
  with_labeled_metric(Name, LabelValues, fun(M) -> instrument_gauge:dec_gauge(M, Value) end).

-spec set_gauge_vec(Name :: metric_name(), LabelValues :: list(), Value :: number()) -> ok | {error, term()}.
set_gauge_vec(Name, LabelValues, Value) ->
  with_labeled_metric(Name, LabelValues, fun(M) -> instrument_gauge:set_gauge(M, Value) end).

-spec get_gauge_vec(Name :: metric_name(), LabelValues :: list()) -> float() | {error, term()}.
get_gauge_vec(Name, LabelValues) ->
  with_labeled_metric(Name, LabelValues, fun instrument_gauge:get_gauge/1).

-spec observe_histogram_vec(Name :: metric_name(), LabelValues :: list(), Value :: number()) -> ok | {error, term()}.
observe_histogram_vec(Name, LabelValues, Value) ->
  with_labeled_metric(Name, LabelValues, fun(M) -> instrument_histogram:observe_histogram(M, Value) end).

-spec get_histogram_vec(Name :: metric_name(), LabelValues :: list()) -> map() | {error, term()}.
get_histogram_vec(Name, LabelValues) ->
  with_labeled_metric(Name, LabelValues, fun instrument_histogram:get_histogram/1).

%% Internal helper for vec operations
with_labeled_metric(Name, LabelValues, Fun) ->
  case instrument_vector:get_or_create_label(Name, LabelValues) of
    {ok, Metric} -> Fun(Metric);
    Error -> Error
  end.