%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Pluggable context propagator registry.
%%
%% This module provides a registry for context propagators that handle
%% injecting and extracting context from carriers (e.g., HTTP headers).
%%
%% == Built-in Propagators ==
%% - `instrument_propagator_tracecontext' - W3C TraceContext
%% - `instrument_propagator_baggage' - W3C Baggage
%%
%% == Example Usage ==
%% ```
%% %% Register a propagator
%% instrument_propagator:register(instrument_propagator_tracecontext).
%%
%% %% Get all registered propagators
%% Propagators = instrument_propagator:list().
%%
%% %% Inject context using all propagators
%% Carrier = instrument_propagator:inject(#{}).
%%
%% %% Extract context using all propagators
%% Ctx = instrument_propagator:extract(Carrier).
%% '''
-module(instrument_propagator).
-author("benoitc").

-include("instrument_otel.hrl").

%% API
-export([
  register/1,
  unregister/1,
  list/0,
  set_propagators/1,
  get_propagators/0,
  inject/1,
  inject/2,
  extract/1,
  extract/2,
  fields/0
]).

-define(PROPAGATORS_KEY, '$instrument_propagators').

%% Behavior callbacks
-callback inject(Ctx :: map(), Carrier :: map()) -> map().
-callback extract(Carrier :: map(), Ctx :: map()) -> map().
-callback fields() -> [binary()].

%% ============================================================================
%% API
%% ============================================================================

%% @doc Registers a propagator module.
-spec register(module()) -> ok.
register(Module) when is_atom(Module) ->
  Propagators = persistent_term:get(?PROPAGATORS_KEY, default_propagators()),
  case lists:member(Module, Propagators) of
    true -> ok;
    false ->
      persistent_term:put(?PROPAGATORS_KEY, Propagators ++ [Module]),
      ok
  end.

%% @doc Unregisters a propagator module.
-spec unregister(module()) -> ok.
unregister(Module) when is_atom(Module) ->
  Propagators = persistent_term:get(?PROPAGATORS_KEY, default_propagators()),
  NewPropagators = lists:delete(Module, Propagators),
  persistent_term:put(?PROPAGATORS_KEY, NewPropagators),
  ok.

%% @doc Lists all registered propagators.
-spec list() -> [module()].
list() ->
  persistent_term:get(?PROPAGATORS_KEY, default_propagators()).

%% @doc Sets the list of propagators (replacing existing ones).
-spec set_propagators([module()]) -> ok.
set_propagators(Modules) when is_list(Modules) ->
  persistent_term:put(?PROPAGATORS_KEY, Modules),
  ok.

%% @doc Gets the list of registered propagators.
-spec get_propagators() -> [module()].
get_propagators() ->
  list().

%% @doc Injects context into a carrier using all registered propagators.
-spec inject(map()) -> map().
inject(Carrier) when is_map(Carrier) ->
  Ctx = instrument_context:current(),
  inject(Ctx, Carrier).

%% @doc Injects context into a carrier using all registered propagators.
-spec inject(map(), map()) -> map().
inject(Ctx, Carrier) when is_map(Ctx), is_map(Carrier) ->
  Propagators = list(),
  lists:foldl(fun(Module, AccCarrier) ->
    try
      Module:inject(Ctx, AccCarrier)
    catch
      _:_ -> AccCarrier
    end
  end, Carrier, Propagators).

%% @doc Extracts context from a carrier using all registered propagators.
-spec extract(map()) -> map().
extract(Carrier) when is_map(Carrier) ->
  Ctx = instrument_context:new(),
  extract(Carrier, Ctx).

%% @doc Extracts context from a carrier into an existing context.
-spec extract(map(), map()) -> map().
extract(Carrier, Ctx) when is_map(Carrier), is_map(Ctx) ->
  Propagators = list(),
  lists:foldl(fun(Module, AccCtx) ->
    try
      Module:extract(Carrier, AccCtx)
    catch
      _:_ -> AccCtx
    end
  end, Ctx, Propagators).

%% @doc Returns all header fields used by registered propagators.
-spec fields() -> [binary()].
fields() ->
  Propagators = list(),
  lists:usort(lists:flatmap(fun(Module) ->
    try
      Module:fields()
    catch
      _:_ -> []
    end
  end, Propagators)).

%% ============================================================================
%% Internal Functions
%% ============================================================================

default_propagators() ->
  [
    instrument_propagator_tracecontext,
    instrument_propagator_baggage
  ].
