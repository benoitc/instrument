%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc W3C Baggage propagator.
%%
%% This propagator handles the W3C Baggage specification for
%% propagating application-defined key-value pairs.
%%
%% See: https://www.w3.org/TR/baggage/
-module(instrument_propagator_baggage).
-author("benoitc").

-behaviour(instrument_propagator).

-export([
  inject/2,
  extract/2,
  fields/0
]).

-define(BAGGAGE_HEADER, <<"baggage">>).

%% ============================================================================
%% Propagator Callbacks
%% ============================================================================

%% @doc Injects baggage into a carrier.
-spec inject(map(), map()) -> map().
inject(Ctx, Carrier) when is_map(Ctx), is_map(Carrier) ->
  Baggage = instrument_baggage:from_context(Ctx),
  case map_size(Baggage) of
    0 -> Carrier;
    _ ->
      Value = instrument_baggage:encode(Baggage),
      maps:put(?BAGGAGE_HEADER, Value, Carrier)
  end.

%% @doc Extracts baggage from a carrier.
-spec extract(map(), map()) -> map().
extract(Carrier, Ctx) when is_map(Carrier), is_map(Ctx) ->
  case maps:get(?BAGGAGE_HEADER, Carrier, undefined) of
    undefined -> Ctx;
    Value ->
      Baggage = instrument_baggage:decode(Value),
      instrument_baggage:to_context(Ctx, Baggage)
  end.

%% @doc Returns the header fields used by this propagator.
-spec fields() -> [binary()].
fields() ->
  [?BAGGAGE_HEADER].
