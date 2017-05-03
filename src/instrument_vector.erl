%% Copyright (c) 2017, Benoit Chesneau <bchesneau@gmail.com>.
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
  clear_labels/1
]).

-include("instrument.hrl").


new(Labels, histogram, Name, Help) ->
  new(Labels, histogram, Name, Help, instrument_histogram:default_buckets());
new(Labels, MetricType, Name, Help) ->
  new(Labels, MetricType, Name, Help, []).

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
    fun(#metric{ name=Name, handle = Vector }=_M) ->
      io:format("got metric ~p~n", [_M]),
      case find_label(Label, Vector) of
        {ok, Metric} ->
          case Mod of
            undefined -> erlang:apply(Fun, [Metric | Args]);
            _ -> erlang:apply(Mod, Fun, [Metric | Args])
          end;
        {error, _}=Error ->
          Error;
        error ->
          ok = instrument_registry:create_vector_metric(Name, Label),
          with_label(Name, Label, Fun)
      end
    end
  ).

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

validate_metric_type(counter) -> ok;
validate_metric_type({gauge}) -> ok;
validate_metric_type(histogram) -> ok;
validate_metric_type(_) -> erlang:error(bad_metric).

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