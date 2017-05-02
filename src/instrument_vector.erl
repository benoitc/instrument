%% Copyright (c) 2017, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_vector).
-author("benoitc").

%% API
-export([
  new/4, new/5,
  with_label/3,
  with/2,
  has_label/2,
  remove_label/2,
  clear_labels/1
]).

-export([
  maybe_create_metric/2
]).

-include("instrument.hrl").


-record(vector, {
  name,
  help,
  metric,
  buckets = [],
  labels = [],
  labels_map = #{}
}).

new(Labels, histogram, Name, Help) ->
  new(Name, Help, Labels, histogram, instrument_histogram:default_buckets());
new(Labels, Metric, Name, Help) ->
  ok = validate_metric_type(Metric),
  Vector = #vector{
    name = Name,
    help = Help,
    metric = Metric,
    labels = Labels
  },
  
  #metric{
    name=Name,
    handle=Vector,
    collect = {?MODULE, collect, [Vector]}
  }.

new(Labels, histogram, Name, Help, Buckets) ->
  Vector = #vector{
    name = Name,
    help = Help,
    metric = histogram,
    buckets = Buckets,
    labels = Labels
  },
  
  #metric{
    name=Name,
    handle=Vector,
    collect = {?MODULE, collect, [Vector]}
  };
new(_, _, _, _, _) ->
  erlang:error(bad_metric).


with_label(#metric{ handle = Vector}=VectorMetric, Label, Fun) ->
  {Metric, Vector2} = maybe_create_metric(Label, Vector),
  Res = instrument_lib:apply_fun(Fun, Metric),
  {Res, VectorMetric#metric{ handle = Vector2 }}.


with(#metric{ handle = Vector}, Fun) ->
  maps:fold(
    fun(Labels, M, Acc) ->
      Res = instrument_lib:apply_fun(Fun, M),
      [{Labels, Res} | Acc]
    end,
    [],
    Vector#vector.labels_map
  ).


remove_label(#metric{handle=Vector}=VectorMetric, Label) ->
  Map2 = maps:remove(Label, Vector#vector.labels_map),
  Vector2 = Vector#vector{labels_map = Map2},
  VectorMetric#metric{handle=Vector2}.
  

clear_labels(#metric{handle=Vector}=VectorMetric) ->
  Vector2 = Vector#vector{labels_map=#{}},
  VectorMetric#metric{handle=Vector2}.

has_label(#metric{ handle = Vector}, Label) ->
  has_label_1(Label, Vector).


has_label_1(LabelsValues, #vector{}=Vector) when is_list(LabelsValues) ->
  VLen = length(LabelsValues),
  GLen = length(Vector#vector.labels),
  if
    VLen =:= GLen ->
      maps:is_key(LabelsValues, Vector#vector.labels_map);
    true ->
      {error, bad_labels}
        end;
has_label_1(LabelsValuesMap, #vector{}=Vector) when is_map(LabelsValuesMap) ->
  #vector{ labels = Labels, labels_map = Map } = Vector,
  MLen = maps:size(LabelsValuesMap),
  GLen = length(Labels),
  if
    MLen =:= GLen ->
      LabelsValues = maps:values(maps:with(Labels, LabelsValuesMap)),
      maps:is_key(LabelsValues, Map);
    true ->
      {error, bad_labels}
  end;
has_label_1(_, _) ->
  erlang:error(badarg).

maybe_create_metric(LabelsValues, #vector{}=Vector) when is_list(LabelsValues) ->
  VLen = length(LabelsValues),
  GLen = length(Vector#vector.labels),
  if
    VLen =:= GLen ->
      maybe_create_metric_1(LabelsValues, Vector);
    true ->
      io:format("vector is ~p: ~p / ~p ~n", [Vector, VLen, GLen]),
      {error, bad_labels}
  end;
maybe_create_metric(LabelsValuesMap, #vector{}=Vector) when is_map(LabelsValuesMap) ->
  #vector{ labels = Labels } = Vector,
  MLen = maps:size(LabelsValuesMap),
  GLen = length(Labels),
  if
    MLen =:= GLen ->
      LabelsValues = maps:values(maps:with(Labels, LabelsValuesMap)),
      maybe_create_metric(LabelsValues, Vector);
    true ->
      {error, bad_labels}
  end;
maybe_create_metric(_, _) ->
  erlang:error(badarg).

maybe_create_metric_1(LabelsValues, Vector) ->
  #vector{ labels_map = LabelsMap } = Vector,
  case maps:find(LabelsValues, LabelsMap) of
    {ok, Metric} -> {Metric, Vector};
    error ->
      Metric = mk_metric(Vector),
      LabelsMap2 = maps:put(LabelsValues, Metric, LabelsMap),
      {Metric, Vector#vector{labels_map=LabelsMap2}}
      
  end.

validate_metric_type(counter) -> ok;
validate_metric_type({gauge}) -> ok;
validate_metric_type(histogram) -> ok;
validate_metric_type(_) -> erlang:error(bad_metric).

mk_metric(#vector{name=Name, help=Help, metric=counter}) ->
  instrument_counter:new(Name, Help);
mk_metric(#vector{name=Name, help=Help, metric=gauge}) ->
  instrument_gauge:new(Name, Help);
mk_metric(#vector{name=Name, help=Help, metric=histogram, buckets=Buckets}) ->
  instrument_histogram:new(Name, Help, Buckets).

