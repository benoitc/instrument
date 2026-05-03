%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Exemplar reservoir sampling for metrics.
%%
%% Implements fixed-size reservoir sampling for collecting exemplars
%% with trace context per OTel spec. Default reservoir size is 4.
%%
%% Exemplars capture representative observations with their trace context,
%% allowing correlation between metrics and traces.
-module(instrument_exemplar).
-author("benoitc").

-export([
  new_reservoir/0,
  new_reservoir/1,
  offer/3,
  offer/4,
  collect/1,
  reset/1,
  %% ETS-based API for histogram integration
  init_table/0,
  new_reservoir_ref/0,
  new_reservoir_ref/1,
  offer_ref/3,
  collect_ref/1,
  reset_ref/1,
  delete_reservoir/1
]).

-include("instrument_otel.hrl").

-define(DEFAULT_RESERVOIR_SIZE, 4).

-record(reservoir, {
  size :: pos_integer(),
  count = 0 :: non_neg_integer(),
  exemplars = [] :: [#exemplar{}]
}).

-opaque reservoir() :: #reservoir{}.
-export_type([reservoir/0]).

%% ============================================================================
%% API
%% ============================================================================

%% @doc Creates a new exemplar reservoir with default size (4).
-spec new_reservoir() -> reservoir().
new_reservoir() ->
  new_reservoir(?DEFAULT_RESERVOIR_SIZE).

%% @doc Creates a new exemplar reservoir with specified size.
-spec new_reservoir(pos_integer()) -> reservoir().
new_reservoir(Size) when is_integer(Size), Size > 0 ->
  #reservoir{size = Size, count = 0, exemplars = []}.

%% @doc Offers a value to the reservoir with automatic trace context capture.
%% Uses reservoir sampling to maintain a fixed-size sample.
-spec offer(reservoir(), number(), map()) -> reservoir().
offer(Reservoir, Value, FilteredAttributes) ->
  {TraceId, SpanId} = get_trace_context(),
  offer(Reservoir, Value, FilteredAttributes, {TraceId, SpanId}).

%% @doc Offers a value to the reservoir with explicit trace context.
-spec offer(reservoir(), number(), map(), {binary() | undefined, binary() | undefined}) -> reservoir().
offer(#reservoir{size = Size, count = Count, exemplars = Exemplars} = R, Value, FilteredAttrs, {TraceId, SpanId}) ->
  Timestamp = erlang:system_time(nanosecond),
  Exemplar = #exemplar{
    filtered_attributes = FilteredAttrs,
    value = Value,
    timestamp = Timestamp,
    span_id = SpanId,
    trace_id = TraceId
  },
  NewCount = Count + 1,
  case NewCount =< Size of
    true ->
      %% Reservoir not full - add directly
      R#reservoir{count = NewCount, exemplars = [Exemplar | Exemplars]};
    false ->
      %% Reservoir full - use reservoir sampling (random replacement)
      %% With probability Size/NewCount, replace a random exemplar
      case rand:uniform(NewCount) =< Size of
        true ->
          %% Replace random exemplar
          Idx = rand:uniform(Size),
          NewExemplars = replace_at(Exemplars, Idx, Exemplar),
          R#reservoir{count = NewCount, exemplars = NewExemplars};
        false ->
          %% Keep existing exemplars
          R#reservoir{count = NewCount}
      end
  end.

%% @doc Collects all exemplars from the reservoir.
-spec collect(reservoir()) -> [#exemplar{}].
collect(#reservoir{exemplars = Exemplars}) ->
  lists:reverse(Exemplars).

%% @doc Resets the reservoir, clearing all exemplars.
-spec reset(reservoir()) -> reservoir().
reset(#reservoir{size = Size}) ->
  #reservoir{size = Size, count = 0, exemplars = []}.

%% ============================================================================
%% Internal Functions
%% ============================================================================

%% Get current trace context from the active span
get_trace_context() ->
  case instrument_tracer:span_ctx() of
    #span_ctx{trace_id = TraceId, span_id = SpanId} ->
      {TraceId, SpanId};
    undefined ->
      {undefined, undefined}
  end.

%% Replace element at 1-based index in list
replace_at(List, Idx, NewElem) ->
  replace_at(List, Idx, NewElem, 1, []).

replace_at([_ | Rest], Idx, NewElem, Idx, Acc) ->
  lists:reverse(Acc) ++ [NewElem | Rest];
replace_at([H | Rest], Idx, NewElem, Current, Acc) ->
  replace_at(Rest, Idx, NewElem, Current + 1, [H | Acc]);
replace_at([], _, _, _, Acc) ->
  lists:reverse(Acc).

%% ============================================================================
%% ETS-based API for histogram integration
%% ============================================================================

-define(EXEMPLAR_TABLE, instrument_exemplar_reservoirs).

%% @doc Initialize the ETS table for exemplar storage.
%% Called during application startup.
-spec init_table() -> ok.
init_table() ->
  case ets:whereis(?EXEMPLAR_TABLE) of
    undefined ->
      ets:new(?EXEMPLAR_TABLE, [named_table, public, set, {write_concurrency, true}]);
    _ ->
      ok
  end,
  ok.

%% @doc Creates a new reservoir with default size and returns a reference key.
-spec new_reservoir_ref() -> reference().
new_reservoir_ref() ->
  new_reservoir_ref(?DEFAULT_RESERVOIR_SIZE).

%% @doc Creates a new reservoir with specified size and returns a reference key.
-spec new_reservoir_ref(pos_integer()) -> reference().
new_reservoir_ref(Size) ->
  ensure_table(),
  Ref = make_ref(),
  Reservoir = new_reservoir(Size),
  ets:insert(?EXEMPLAR_TABLE, {Ref, Reservoir}),
  Ref.

%% @doc Offers a value to the reservoir identified by reference.
-spec offer_ref(reference(), number(), map()) -> ok.
offer_ref(Ref, Value, FilteredAttributes) ->
  case ets:lookup(?EXEMPLAR_TABLE, Ref) of
    [{Ref, Reservoir}] ->
      NewReservoir = offer(Reservoir, Value, FilteredAttributes),
      ets:insert(?EXEMPLAR_TABLE, {Ref, NewReservoir}),
      ok;
    [] ->
      ok
  end.

%% @doc Collects all exemplars from the reservoir identified by reference.
-spec collect_ref(reference() | undefined) -> [#exemplar{}].
collect_ref(undefined) ->
  [];
collect_ref(Ref) ->
  case ets:lookup(?EXEMPLAR_TABLE, Ref) of
    [{Ref, Reservoir}] ->
      collect(Reservoir);
    [] ->
      []
  end.

%% @doc Resets the reservoir identified by reference.
-spec reset_ref(reference()) -> ok.
reset_ref(Ref) ->
  case ets:lookup(?EXEMPLAR_TABLE, Ref) of
    [{Ref, Reservoir}] ->
      NewReservoir = reset(Reservoir),
      ets:insert(?EXEMPLAR_TABLE, {Ref, NewReservoir}),
      ok;
    [] ->
      ok
  end.

%% @doc Deletes the reservoir identified by reference. Safe to call with
%% `undefined' or a reference that is no longer present.
-spec delete_reservoir(reference() | undefined) -> ok.
delete_reservoir(undefined) ->
  ok;
delete_reservoir(Ref) when is_reference(Ref) ->
  case ets:whereis(?EXEMPLAR_TABLE) of
    undefined -> ok;
    _ ->
      ets:delete(?EXEMPLAR_TABLE, Ref),
      ok
  end.

%% Ensure the ETS table exists
ensure_table() ->
  case ets:whereis(?EXEMPLAR_TABLE) of
    undefined ->
      try
        ets:new(?EXEMPLAR_TABLE, [named_table, public, set, {write_concurrency, true}])
      catch
        error:badarg -> ok  %% Table already exists (race condition)
      end;
    _ ->
      ok
  end.
