%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Context propagation helpers for cross-process communication.
%%
%% This module provides helpers for propagating context across process
%% boundaries and encoding/decoding W3C TraceContext format.
-module(instrument_propagation).
-author("benoitc").

%% Process spawn helpers
-export([
  spawn/1,
  spawn/2,
  spawn_link/1,
  spawn_link/2,
  spawn_monitor/1,
  spawn_opt/2
]).

%% Gen behavior helpers
-export([
  call_with_context/2,
  call_with_context/3,
  cast_with_context/2
]).

%% W3C TraceContext format
-export([
  inject/1,
  inject/2,
  extract/1,
  extract/2
]).

%% Headers extraction/injection
-export([
  inject_headers/1,
  extract_headers/1
]).

-include("instrument_otel.hrl").

%% Process spawn helpers

%% @doc Spawns a process with the current context propagated.
-spec spawn(fun(() -> term())) -> pid().
spawn(Fun) when is_function(Fun, 0) ->
  instrument_context:spawn_with_context(Fun).

%% @doc Spawns a process with args and the current context propagated.
-spec spawn(fun((...) -> term()), list()) -> pid().
spawn(Fun, Args) when is_function(Fun), is_list(Args) ->
  Ctx = instrument_context:current(),
  erlang:spawn(fun() ->
    _ = instrument_context:attach(Ctx),
    erlang:apply(Fun, Args)
  end).

%% @doc Spawns a linked process with the current context propagated.
-spec spawn_link(fun(() -> term())) -> pid().
spawn_link(Fun) when is_function(Fun, 0) ->
  instrument_context:spawn_link_with_context(Fun).

%% @doc Spawns a linked process with args and the current context propagated.
-spec spawn_link(fun((...) -> term()), list()) -> pid().
spawn_link(Fun, Args) when is_function(Fun), is_list(Args) ->
  Ctx = instrument_context:current(),
  erlang:spawn_link(fun() ->
    _ = instrument_context:attach(Ctx),
    erlang:apply(Fun, Args)
  end).

%% @doc Spawns a monitored process with the current context propagated.
-spec spawn_monitor(fun(() -> term())) -> {pid(), reference()}.
spawn_monitor(Fun) when is_function(Fun, 0) ->
  Ctx = instrument_context:current(),
  erlang:spawn_monitor(fun() ->
    _ = instrument_context:attach(Ctx),
    Fun()
  end).

%% @doc Spawns a process with options and the current context propagated.
-spec spawn_opt(fun(() -> term()), [term()]) -> pid() | {pid(), reference()}.
spawn_opt(Fun, Opts) when is_function(Fun, 0), is_list(Opts) ->
  Ctx = instrument_context:current(),
  erlang:spawn_opt(fun() ->
    _ = instrument_context:attach(Ctx),
    Fun()
  end, Opts).

%% Gen behavior helpers

%% @doc Makes a gen_server call with the current context propagated.
%% The server must be aware of context propagation to use this.
-spec call_with_context(term(), term()) -> term().
call_with_context(ServerRef, Request) ->
  call_with_context(ServerRef, Request, 5000).

%% @doc Makes a gen_server call with the current context propagated and timeout.
-spec call_with_context(term(), term(), timeout()) -> term().
call_with_context(ServerRef, Request, Timeout) ->
  Ctx = instrument_context:current(),
  gen_server:call(ServerRef, {'$instrument_call', Ctx, Request}, Timeout).

%% @doc Makes a gen_server cast with the current context propagated.
-spec cast_with_context(term(), term()) -> ok.
cast_with_context(ServerRef, Msg) ->
  Ctx = instrument_context:current(),
  gen_server:cast(ServerRef, {'$instrument_cast', Ctx, Msg}).

%% W3C TraceContext format

%% @doc Injects the current trace context into a carrier (map).
%% Uses all registered propagators.
-spec inject(map()) -> map().
inject(Carrier) when is_map(Carrier) ->
  instrument_propagator:inject(Carrier).

%% @doc Injects trace context into a carrier (map).
%% Uses all registered propagators.
-spec inject(instrument_context:context(), map()) -> map().
inject(Ctx, Carrier) when is_map(Ctx), is_map(Carrier) ->
  instrument_propagator:inject(Ctx, Carrier).

%% @doc Extracts trace context from a carrier (map).
%% Uses all registered propagators.
-spec extract(map()) -> instrument_context:context().
extract(Carrier) when is_map(Carrier) ->
  instrument_propagator:extract(Carrier).

%% @doc Extracts trace context from a carrier into an existing context.
%% Uses all registered propagators.
-spec extract(map(), instrument_context:context()) -> instrument_context:context().
extract(Carrier, Ctx) when is_map(Carrier), is_map(Ctx) ->
  instrument_propagator:extract(Carrier, Ctx).

%% @doc Injects context into HTTP headers format.
-spec inject_headers(instrument_context:context()) -> [{binary(), binary()}].
inject_headers(Ctx) ->
  Carrier = inject(Ctx, #{}),
  maps:to_list(Carrier).

%% @doc Extracts context from HTTP headers.
-spec extract_headers([{binary() | string(), binary() | string()}]) -> instrument_context:context().
extract_headers(Headers) ->
  Carrier = lists:foldl(fun({K, V}, Acc) ->
    KeyBin = to_lower_binary(K),
    ValBin = to_binary(V),
    maps:put(KeyBin, ValBin, Acc)
  end, #{}, Headers),
  extract(Carrier).

%% Internal functions

to_binary(V) when is_binary(V) -> V;
to_binary(V) when is_list(V) -> list_to_binary(V);
to_binary(V) when is_atom(V) -> atom_to_binary(V, utf8).

to_lower_binary(V) ->
  string:lowercase(to_binary(V)).
