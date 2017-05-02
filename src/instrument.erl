%% Copyright (c) 2017, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.
-module(instrument).
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

%% VECTOR API
-export([
  new_vector/4, new_vector/5,
  get_vector_with/2,
  get_vector_with/3,
  with_label/3,
  remove_label/2,
  clear_labels/1
]).

%% SHARED API

-export([
  new_shared_counter/2,
  with_shared/2,
  with_shared/3,
  get_shared_vector_with/2,
  get_shared_vector_with/3,
  shared_with_label/3,
  shared_with_label/4,
  unreg/1
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
  instrument_counter:new(Name, Help).

-spec inc_counter(Counter :: metric()) -> Result :: ok | {error, not_found}.
inc_counter(Counter) ->
  instrument_counter:inc(Counter).


-spec inc_counter(Counter :: metric(), Value :: number()) -> Result :: ok | {error, not_found}.
inc_counter(Counter, Value) ->
  instrument_counter:inc(Counter, Value).


-spec get_counter(Counter :: metric()) -> Result :: float() | {error, not_found}.
get_counter(Counter) ->
  instrument_counter:get(Counter).
  

%% GAUGE

-spec new_gauge(Name :: metric_name(), Help :: help()) -> Gauge :: metric().
new_gauge(Name, Help) ->
  instrument_gauge:new(Name, Help).



-spec inc_gauge(Gauge :: metric()) -> Result :: ok | {error, not_found}.
inc_gauge(Gauge) ->
  instrument_gauge:inc(Gauge).


-spec inc_gauge(Gauge :: metric(), Value :: number()) -> Result :: ok | {error, not_found}.
inc_gauge(Gauge, Value) ->
  instrument_gauge:inc(Gauge, Value).

-spec dec_gauge(Gauge :: metric()) -> Result :: ok | {error, not_found}.
dec_gauge(Gauge) ->
  instrument_gauge:dec(Gauge).


-spec dec_gauge(Gauge :: metric(), Value :: number()) -> Result :: ok | {error, not_found}.
dec_gauge(Gauge, Value) ->
  instrument_gauge:dec(Gauge, Value).

-spec set_gauge(Gauge :: metric(), Value :: number()) -> Result :: ok | {error, not_found}.
set_gauge(Gauge, Value) ->
  instrument_gauge:set(Gauge, Value).

-spec set_gauge_to_current_time(Gauge :: metric()) -> Result :: ok | {error, not_found}.
set_gauge_to_current_time(Gauge) ->
  instrument_gauge:set_to_current_time(Gauge).


-spec get_gauge(Gauge :: metric()) -> Result :: float() | {error, not_found}.
get_gauge(Gauge) ->
  instrument_gauge:get(Gauge).

%% HISTOGRAM

-spec new_histogram(Name :: metric_name(), Help :: help()) -> Hist::metric().
new_histogram(Name, Help) ->
  instrument_histogram:new(Name, Help).

-spec new_histogram(Name :: metric_name(), Help :: help(), Buckets::list()) -> Hist::metric().
new_histogram(Name, Help, Buckets) ->
  instrument_histogram:new(Name, Help, Buckets).

-spec observe_histogram(Hist::metric(), Value::number()) -> ok | {error, not_found}.
observe_histogram(Hist, Value) ->
  instrument_histogram:observe(Hist, Value).

-spec get_histogram(Hist :: metric()) -> Value :: term().
get_histogram(Hist) ->
  instrument_histogram:get(Hist).

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


-spec get_vector_with(Vector :: metric(), Fun :: mfa()) -> Result :: term().
get_vector_with(Vector, Fun) ->
  instrument_vector:with(Vector, fun(Metric) -> Fun(Metric) end).

get_vector_with(Vector, Fun, V) ->
  instrument_vector:with(Vector, fun(Metric) -> Fun(Metric, V) end).


-spec remove_label(Vector :: metric(), Label :: label_value()) -> Result :: term().
remove_label(Vector, Label) ->
  instrument_vector:remove_label(Vector, Label).

-spec clear_labels(Vector :: metric()) -> ok.
clear_labels(Vector) ->
  instrument_vector:clear_labels(Vector).



%% SHARED API

new_shared_counter(Name, Help) ->
  Metric = new_counter(Name, Help),
  instrument_shared:reg(Metric).


with_shared(Name, Fun) ->
  instrument_shared:with(Name, fun(Metric) -> ?MODULE:Fun(Metric) end).

with_shared(Name, Fun, V) ->
  instrument_shared:with(Name, fun(Metric) -> ?MODULE:Fun(Metric, V) end).

get_shared_vector_with(Name, Fun) ->
  instrument_shared:with_vector(Name, {?MODULE, Fun}).

get_shared_vector_with(Name, Fun, V) ->
  instrument_shared:with_vector(Name, {?MODULE, Fun, V}).

shared_with_label(Name, Label, Fun) ->
  instrument_shared:with_label(Name, Label, {?MODULE, Fun}).

shared_with_label(Name, Label, Fun, V) ->
  instrument_shared:with_label(Name, Label, {?MODULE, Fun, V}).

unreg(Name) ->
  instrument_shared:unreg(Name).
