%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Thin wrapper for the legacy labeled-metric API over the series store.
%%
%% Vec families live in instrument_series keyed by their declared label names;
%% the old fixed-schema container record is gone. Operations resolve a row by
%% the raw label-values list (the cache key) and apply a per-kind function to
%% it. with/2 enumerates a family by walking its row chain.
-module(instrument_vector).
-author("benoitc").

%% API
-export([
  new/4, new/5,
  with_label/3, with_label/4,
  with/2,
  remove_label/2,
  clear_labels/1,
  get_or_create_label/2
]).

-include("instrument.hrl").

-type metric_name() :: atom() | binary() | string().
-type label_values() :: list().

%% new/4,5 register a family with its declared labels and return a minimal
%% #metric{} carrying only the name. The returned record is an opaque handle:
%% with_label/with resolve the family by its name field (the storage lives in
%% the series store, never in the record), so handle is left undefined.
-spec new(list(), atom(), metric_name(), binary() | string()) -> #metric{}.
new(Labels, histogram, Name, Help) ->
  new(Labels, histogram, Name, Help, instrument_histogram:default_buckets());
new(Labels, MetricType, Name, Help) ->
  new(Labels, MetricType, Name, Help, undefined).

-spec new(list(), atom(), metric_name(), binary() | string(), list() | undefined) -> #metric{}.
new(Labels, MetricType, Name, Help, Buckets) ->
  ok = validate_metric_type(MetricType),
  _ = instrument_series:ensure_family(Name, MetricType, to_help(Help), Labels, Buckets),
  #metric{name = Name, handle = undefined}.

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
  Name = vec_name(VectorMetric),
  case label_values(Name, Label) of
    {error, _} = Error ->
      Error;
    LabelValues ->
      %% The closure carries Args through first touch — this is the fix for
      %% master's with_label/4 dropping its value on the first write of a label
      %% set (it recursed into the 3-arity form). instrument_series:write
      %% applies it to the resolved row on both the hot and first-touch paths.
      instrument_series:write(Name, LabelValues,
        fun() -> canon(Name, LabelValues) end,
        fun(Row) -> apply_label_fun(Row, Mod, Fun, Args) end)
  end.

apply_label_fun(Metric, undefined, Fun, Args) ->
  erlang:apply(Fun, [Metric | Args]);
apply_label_fun(Metric, Mod, Fun, Args) ->
  erlang:apply(Mod, Fun, [Metric | Args]).

%% Fold every live label set of a family, applying the getter to each row.
%% Returns [{LabelValues, Result}] in insertion (chain) order, where
%% LabelValues is the declared-order values list the caller originally passed
%% (the stored CacheKey).
with(VectorMetric, Fun) ->
  Name = vec_name(VectorMetric),
  Mod = module(Fun),
  case instrument_series:family(Name) of
    #family{row_seq = Seq} ->
      N = atomics:get(Seq, 1),
      %% foldl prepends, so reverse to yield insertion (chain) order — the
      %% legacy suite pins the order label sets were first written in.
      lists:reverse(lists:foldl(fun(S, Acc) ->
        case persistent_term:get({instrument_row, Name, S}, undefined) of
          {_Canon, CacheKey, Row} ->
            [{CacheKey, apply_label_fun(Row, Mod, Fun, [])} | Acc];
          undefined ->
            Acc
        end
      end, [], lists:seq(1, N)));
    _ ->
      []
  end.

remove_label(Name, Label) ->
  instrument_registry:remove_label(vec_name(Name), Label).

clear_labels(Name) ->
  instrument_registry:clear_labels(vec_name(Name)).

%% @deprecated retained for API compatibility; no internal callers — prefer instrument_metric:labels/2
%% get_or_create_label/2 - resolve or create the row for a label set.
-spec get_or_create_label(metric_name(), label_values()) -> {ok, #metric{}} | {error, term()}.
get_or_create_label(Name0, LabelValues) ->
  Name = vec_name(Name0),
  case persistent_term:get({instrument_label, Name, LabelValues}, undefined) of
    #metric{} = Row ->
      {ok, Row};
    undefined ->
      case instrument_series:write(Name, LabelValues,
                                   fun() -> canon(Name, LabelValues) end,
                                   fun(_R) -> ok end) of
        ok -> {ok, row(Name, LabelValues)};
        Error -> Error
      end
  end.

validate_metric_type(counter)            -> ok;
validate_metric_type(gauge)              -> ok;
validate_metric_type(histogram)          -> ok;
validate_metric_type(observable_counter) -> ok;
validate_metric_type(_)                  -> erlang:error(bad_metric).

%% Resolve the family name from either a #metric{} handle or a bare name.
vec_name(#metric{name = Name}) -> Name;
vec_name(Name) -> Name.

%% Normalize a label argument to a declared-order values list. A positional
%% list is used as-is; a MAP is resolved by picking the declared keys in
%% declared order (so a map and the equivalent positional list resolve the same
%% row). Arity mismatches surface as {error, _} without touching the store.
label_values(Name, Label) when is_list(Label) ->
  case declared(Name) of
    undefined -> {error, not_found};
    Declared when length(Declared) =:= length(Label) -> Label;
    _ -> {error, invalid_labels}
  end;
label_values(Name, LabelMap) when is_map(LabelMap) ->
  case declared(Name) of
    undefined ->
      {error, not_found};
    Declared ->
      case maps:size(LabelMap) =:= length(Declared)
           andalso lists:all(fun(K) -> maps:is_key(K, LabelMap) end, Declared) of
        true -> [maps:get(K, LabelMap) || K <- Declared];
        false -> {error, bad_labels}
      end
  end;
label_values(_Name, _Label) ->
  {error, bad_labels}.

declared(Name) ->
  case instrument_series:family(Name) of
    #family{declared_labels = Declared} -> Declared;
    _ -> undefined
  end.

%% Canonicalize a values list against declared names (sort by name, reorder
%% values). On arity mismatch return a sentinel {[], Values} so the series
%% store's valid_arity/2 rejects it as {error, invalid_labels} (no crash).
canon(Name, LabelValues) ->
  case declared(Name) of
    Declared when is_list(Declared), length(Declared) =:= length(LabelValues) ->
      Pairs = lists:zip(Declared, LabelValues),
      Sorted = lists:keysort(1, Pairs),
      {[K || {K, _} <- Sorted], [to_label_value(V) || {_, V} <- Sorted]};
    _ ->
      {[], LabelValues}
  end.

%% Resolve a written row by its values-list cache key, with the arbiter-row
%% fallback for the brief publication race.
row(Name, LabelValues) ->
  case persistent_term:get({instrument_label, Name, LabelValues}, undefined) of
    #metric{} = R -> R;
    undefined ->
      case ets:lookup_element(instrument_series, {Name, canon(Name, LabelValues)}, 2, undefined) of
        #metric{} = R -> R;
        undefined -> {error, not_found}
      end
  end.

to_help(Help) when is_binary(Help) -> Help;
to_help(Help) when is_list(Help) ->
  try iolist_to_binary(Help)
  catch error:badarg -> iolist_to_binary(io_lib:format("~p", [Help]))
  end;
to_help(Help) ->
  iolist_to_binary(io_lib:format("~p", [Help])).

to_label_value(V) when is_binary(V)  -> V;
to_label_value(V) when is_list(V)    -> list_to_binary(V);
to_label_value(V) when is_atom(V)    -> atom_to_binary(V, utf8);
to_label_value(V) when is_integer(V) -> integer_to_binary(V);
to_label_value(V) when is_float(V)   -> float_to_binary(V, [{decimals, 6}, compact]).
