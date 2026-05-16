%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_vector).
-author("benoitc").

%% API
-export([
  new/4, new/5,
  with_label/3, with_label/4,
  with/2,
  remove_label/2,
  clear_labels/1,
  collect/1,
  get_or_create_label/2
]).

-include("instrument.hrl").

-type metric_name() :: atom() | binary() | string().
-type label_values() :: list().

-spec new(list(), atom(), metric_name(), binary() | string()) -> #metric{}.
new(Labels, histogram, Name, Help) ->
  new(Labels, histogram, Name, Help, instrument_histogram:default_buckets());
new(Labels, MetricType, Name, Help) ->
  new(Labels, MetricType, Name, Help, []).

-spec new(list(), atom(), metric_name(), binary() | string(), list()) -> #metric{}.
new(Labels, MetricType, Name, Help, Buckets) ->
  ok = validate_metric_type(MetricType),
  Vector = #vector{
    name = Name,
    help = Help,
    metric = MetricType,
    buckets = Buckets,
    labels = Labels
  },
  Metric = #metric{
    name=Name,
    handle=Vector,
    collect = {?MODULE, collect, [Name]}
  },
  ok = instrument_registry:register(Metric),
  Metric.

with_label(VectorMetric, Label, Fun) ->
  with_label_1(VectorMetric, Label, module(Fun), Fun, []).
with_label(VectorMetric, Label, Fun, V) ->
  with_label_1(VectorMetric, Label, module(Fun), Fun, [V]).

%% that's pretty hackish but let's do it for now.
module(inc_counter) -> instrument_counter;
module(get_counter) -> instrument_counter;
module(inc_gauge) -> instrument_gauge;
module(dec_gauge) -> instrument_gauge;
module(get_gauge) -> instrument_gauge;
module(set_gauge) -> instrument_gauge;
module(observe_histogram) -> instrument_histogram;
module(get_histogram) -> instrument_histogram;
module(_) -> undefined.

with_label_1(VectorMetric, Label, Mod, Fun, Args) ->
  instrument_registry:with(
    VectorMetric,
    fun(#metric{ name=Name, handle = Vector }) ->
      case find_label(Label, Vector) of
        {ok, Metric} ->
          apply_label_fun(Metric, Mod, Fun, Args);
        {error, _}=Error ->
          Error;
        error ->
          case cardinality_limit_reached(Name) of
            true ->
              case instrument_registry:get_or_create_overflow(Name) of
                undefined -> ok;
                OverflowMetric ->
                  apply_label_fun(OverflowMetric, Mod, Fun, Args)
              end;
            false ->
              ok = instrument_registry:create_vector_metric(Name, Label),
              with_label(Name, Label, Fun)
          end
      end
    end
  ).

apply_label_fun(Metric, undefined, Fun, Args) ->
  erlang:apply(Fun, [Metric | Args]);
apply_label_fun(Metric, Mod, Fun, Args) ->
  erlang:apply(Mod, Fun, [Metric | Args]).

cardinality_limit_reached(Name) ->
  Limit = instrument_config:get_metric_cardinality_limit(),
  instrument_registry:label_count(Name) >= Limit.

with(VectorMetric, Fun) ->
  instrument_registry:with(
    VectorMetric,
    fun(#metric{ handle = Vector }) ->
      maps:fold(
        fun(Labels, M, Acc) ->
          Mod = module(Fun),
          Res = erlang:apply(Mod, Fun, [M]),
          [{Labels, Res} | Acc]
        end,
        [],
        Vector#vector.labels_map
      )
    end
  ).

remove_label(Name, Label) ->
  instrument_registry:remove_label(Name, Label).

clear_labels(Name) ->
  instrument_registry:clear_labels(Name).

validate_metric_type(counter)            -> ok;
validate_metric_type(gauge)              -> ok;
validate_metric_type(histogram)          -> ok;
validate_metric_type(observable_counter) -> ok;
validate_metric_type(_)                  -> erlang:error(bad_metric).

find_label(Label, Vector) when is_list(Label) ->
  VLen = length(Label),
  GLen = length(Vector#vector.labels),
  if
    VLen =:= GLen -> maps:find(Label, Vector#vector.labels_map);
    true -> {error, invalid_labels}
  end;
find_label(LabelMap, #vector{}=Vector) when is_map(LabelMap) ->
  #vector{ labels = Labels } = Vector,
  MLen = maps:size(LabelMap),
  GLen = length(Labels),
  if
    MLen =:= GLen ->
      Label = maps:values(maps:with(Labels, LabelMap)),
      find_label(Label, Vector);
    true ->
      {error, bad_labels}
  end;
find_label(_, _) ->
  {error, bad_labels}.

%% collect/1 - collect all labeled metrics for Prometheus export
-spec collect(metric_name()) -> map().
collect(Name) ->
  case instrument_registry:lookup(Name) of
    undefined ->
      #{name => Name, type => unknown, data => []};
    #metric{handle = #vector{} = Vector} ->
      #vector{help = Help, metric = StoredType,
              labels = LabelNames, labels_map = LabelsMap} = Vector,
      WireType = wire_type(StoredType),
      Data = maps:fold(
        fun(LabelValues, Metric, Acc) ->
          Val = collect_metric_value(StoredType, Metric),
          [{LabelNames, LabelValues, Val} | Acc]
        end,
        [],
        LabelsMap
      ),
      #{name => Name,
        help => Help,
        type => WireType,
        labels => LabelNames,
        data => Data}
  end.

collect_metric_value(counter, Metric) ->
  instrument_counter:get_counter(Metric);
collect_metric_value(gauge, Metric) ->
  instrument_gauge:get_gauge(Metric);
collect_metric_value(histogram, Metric) ->
  instrument_histogram:get_histogram(Metric);
collect_metric_value(observable_counter, Metric) ->
  instrument_gauge:get_gauge(Metric).

%% Map an internal storage type to the Prometheus wire type used by the
%% formatter. observable_counter is gauge-shaped under the hood but renders
%% as counter (and gets the `_total` suffix via format_counter).
wire_type(observable_counter) -> counter;
wire_type(T)                  -> T.

%% get_or_create_label/2 - get or create labeled metric instance
-spec get_or_create_label(metric_name(), label_values()) -> {ok, #metric{}} | {error, term()}.
get_or_create_label(Name, LabelValues) ->
  case instrument_registry:lookup_label(Name, LabelValues) of
    undefined ->
      %% Create the labeled metric
      case instrument_registry:lookup(Name) of
        undefined ->
          {error, not_found};
        #metric{handle = #vector{} = Vector} ->
          #vector{labels = LabelNames} = Vector,
          case length(LabelValues) =:= length(LabelNames) of
            false -> {error, invalid_labels};
            true ->
              case cardinality_limit_reached(Name) of
                true ->
                  case instrument_registry:get_or_create_overflow(Name) of
                    undefined -> {error, not_found};
                    OverflowMetric -> {ok, OverflowMetric}
                  end;
                false ->
                  ok = instrument_registry:create_vector_metric(Name, LabelValues),
                  case instrument_registry:lookup(Name) of
                    #metric{handle = #vector{labels_map = Map}} ->
                      case maps:find(LabelValues, Map) of
                        {ok, Metric} ->
                          instrument_registry:cache_label(Name, LabelValues, Metric),
                          {ok, Metric};
                        error ->
                          {error, not_found}
                      end;
                    _ -> {error, not_found}
                  end
              end
          end
      end;
    Metric ->
      {ok, Metric}
  end.