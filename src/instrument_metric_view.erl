%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc OpenTelemetry Metric Views for transformation and filtering.
%%
%% Metric views allow customizing how metrics are exported by:
%% - Renaming metrics
%% - Changing descriptions
%% - Filtering attributes
%% - Changing aggregation type
%% - Setting histogram bucket boundaries
%%
%% == Example Usage ==
%% ```
%% %% Create a view that renames a metric
%% instrument_metric_view:register(#metric_view{
%%   instrument_name = <<"http_requests">>,
%%   name = <<"http.requests.total">>
%% }).
%%
%% %% Create a view that filters attributes
%% instrument_metric_view:register(#metric_view{
%%   instrument_name = <<"request_latency">>,
%%   attribute_keys = [<<"method">>, <<"status">>]
%% }).
%%
%% %% Apply views to metrics
%% TransformedMetrics = instrument_metric_view:apply_views(Metrics).
%% '''
-module(instrument_metric_view).
-author("benoitc").

-include("instrument_otel.hrl").

%% API
-export([
  register/1,
  unregister/1,
  list/0,
  clear/0,
  apply_views/1,
  match_metric/2
]).

-define(VIEWS_KEY, '$instrument_metric_views').

%% ============================================================================
%% API
%% ============================================================================

%% @doc Registers a metric view.
-spec register(#metric_view{}) -> ok.
register(#metric_view{} = View) ->
  Views = persistent_term:get(?VIEWS_KEY, []),
  persistent_term:put(?VIEWS_KEY, [View | Views]),
  ok.

%% @doc Unregisters a metric view by instrument name pattern.
-spec unregister(binary() | '_') -> ok.
unregister(InstrumentName) ->
  Views = persistent_term:get(?VIEWS_KEY, []),
  NewViews = [V || #metric_view{instrument_name = N} = V <- Views, N =/= InstrumentName],
  persistent_term:put(?VIEWS_KEY, NewViews),
  ok.

%% @doc Lists all registered views.
-spec list() -> [#metric_view{}].
list() ->
  persistent_term:get(?VIEWS_KEY, []).

%% @doc Clears all registered views.
-spec clear() -> ok.
clear() ->
  persistent_term:put(?VIEWS_KEY, []),
  ok.

%% @doc Applies all registered views to a list of metrics.
%% Returns transformed metrics.
-spec apply_views([map()]) -> [map()].
apply_views(Metrics) ->
  Views = list(),
  case Views of
    [] ->
      %% No views registered, return metrics unchanged
      Metrics;
    _ ->
      lists:map(fun(Metric) -> apply_views_to_metric(Metric, Views) end, Metrics)
  end.

%% @doc Checks if a view matches a metric.
-spec match_metric(#metric_view{}, map()) -> boolean().
match_metric(#metric_view{instrument_name = Pattern, instrument_type = TypePattern}, Metric) ->
  Name = maps:get(name, Metric, <<>>),
  Type = maps:get(type, Metric, undefined),
  matches_pattern(Pattern, Name) andalso matches_type_pattern(TypePattern, Type).

%% ============================================================================
%% Internal Functions
%% ============================================================================

apply_views_to_metric(Metric, Views) ->
  %% Find matching views
  MatchingViews = [V || V <- Views, match_metric(V, Metric)],
  %% Apply views in order (later views override earlier ones)
  lists:foldl(fun apply_view/2, Metric, MatchingViews).

apply_view(#metric_view{} = View, Metric) ->
  Metric1 = maybe_rename(View, Metric),
  Metric2 = maybe_update_description(View, Metric1),
  Metric3 = maybe_filter_attributes(View, Metric2),
  maybe_update_boundaries(View, Metric3).

maybe_rename(#metric_view{name = undefined}, Metric) ->
  Metric;
maybe_rename(#metric_view{name = NewName}, Metric) ->
  Metric#{name => NewName}.

maybe_update_description(#metric_view{description = undefined}, Metric) ->
  Metric;
maybe_update_description(#metric_view{description = Desc}, Metric) ->
  Metric#{description => Desc}.

maybe_filter_attributes(#metric_view{attribute_keys = undefined}, Metric) ->
  Metric;
maybe_filter_attributes(#metric_view{attribute_keys = Keys}, Metric) ->
  DataPoints = maps:get(data_points, Metric, []),
  FilteredPoints = lists:map(fun(Point) ->
    Attrs = maps:get(attributes, Point, #{}),
    FilteredAttrs = maps:filter(fun(K, _V) -> lists:member(K, Keys) end, Attrs),
    Point#{attributes => FilteredAttrs}
  end, DataPoints),
  Metric#{data_points => FilteredPoints}.

maybe_update_boundaries(#metric_view{boundaries = undefined}, Metric) ->
  Metric;
maybe_update_boundaries(#metric_view{boundaries = _Boundaries}, #{type := histogram} = Metric) ->
  %% Per OpenTelemetry spec, histogram bucket boundaries are immutable after creation.
  %% Views can specify boundaries, but they only take effect when creating new
  %% histogram instruments, not during metric transformation. The boundaries are
  %% stored in the view for use by instrument creation logic.
  Metric;
maybe_update_boundaries(_View, Metric) ->
  Metric.

matches_pattern('_', _Name) ->
  true;
matches_pattern(Pattern, Name) when is_binary(Pattern), is_binary(Name) ->
  Pattern =:= Name;
matches_pattern(_, _) ->
  false.

matches_type_pattern('_', _Type) ->
  true;
matches_type_pattern(undefined, _Type) ->
  true;
matches_type_pattern(TypePattern, Type) ->
  TypePattern =:= Type.
