%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Context propagation for OpenTelemetry-compatible instrumentation.
%%
%% This module provides context propagation using the process dictionary.
%% Context is immutable; operations return new context values.
%%
%% The context can hold arbitrary key-value pairs and is used to propagate
%% trace context, baggage, and other cross-cutting concerns.
-module(instrument_context).
-author("benoitc").

-export([
  new/0,
  current/0,
  attach/1,
  detach/1,
  get_value/2,
  get_value/3,
  set_value/3,
  remove_value/2,
  with_context/2,
  spawn_with_context/1,
  spawn_with_context/2,
  spawn_link_with_context/1,
  spawn_link_with_context/2
]).

-define(CONTEXT_KEY, '$instrument_context').

-type context() :: #{term() => term()}.
-type token() :: reference().

-export_type([context/0, token/0]).

%% @doc Creates a new empty context.
-spec new() -> context().
new() ->
  #{}.

%% @doc Returns the current context from the process dictionary.
%% If no context is attached, returns an empty context.
-spec current() -> context().
current() ->
  case erlang:get(?CONTEXT_KEY) of
    undefined -> new();
    Ctx -> Ctx
  end.

%% @doc Attaches a context to the current process.
%% Returns a token that must be used with `detach/1' to restore the previous context.
-spec attach(context()) -> token().
attach(Ctx) when is_map(Ctx) ->
  Token = make_ref(),
  PrevCtx = current(),
  erlang:put(?CONTEXT_KEY, Ctx),
  erlang:put({?CONTEXT_KEY, Token}, PrevCtx),
  Token.

%% @doc Detaches the current context and restores the previous one.
%% The token must match the one returned by `attach/1'.
-spec detach(token()) -> ok.
detach(Token) when is_reference(Token) ->
  case erlang:erase({?CONTEXT_KEY, Token}) of
    undefined ->
      %% Token not found, context may have been corrupted
      ok;
    PrevCtx ->
      erlang:put(?CONTEXT_KEY, PrevCtx),
      ok
  end.

%% @doc Gets a value from the context.
%% Returns `undefined' if the key is not found.
-spec get_value(context(), term()) -> term() | undefined.
get_value(Ctx, Key) ->
  get_value(Ctx, Key, undefined).

%% @doc Gets a value from the context with a default.
-spec get_value(context(), term(), term()) -> term().
get_value(Ctx, Key, Default) when is_map(Ctx) ->
  maps:get(Key, Ctx, Default).

%% @doc Sets a value in the context.
%% Returns a new context with the value set.
-spec set_value(context(), term(), term()) -> context().
set_value(Ctx, Key, Value) when is_map(Ctx) ->
  maps:put(Key, Value, Ctx).

%% @doc Removes a value from the context.
%% Returns a new context with the value removed.
-spec remove_value(context(), term()) -> context().
remove_value(Ctx, Key) when is_map(Ctx) ->
  maps:remove(Key, Ctx).

%% @doc Executes a function with the given context attached.
%% The previous context is restored after the function returns.
-spec with_context(context(), fun(() -> Result)) -> Result when Result :: term().
with_context(Ctx, Fun) when is_map(Ctx), is_function(Fun, 0) ->
  Token = attach(Ctx),
  try
    Fun()
  after
    detach(Token)
  end.

%% @doc Spawns a process with the current context propagated.
-spec spawn_with_context(fun(() -> term())) -> pid().
spawn_with_context(Fun) when is_function(Fun, 0) ->
  Ctx = current(),
  spawn(fun() ->
    _ = attach(Ctx),
    Fun()
  end).

%% @doc Spawns a process in a module with the current context propagated.
-spec spawn_with_context(module(), atom()) -> pid().
spawn_with_context(Module, Function) ->
  Ctx = current(),
  spawn(fun() ->
    _ = attach(Ctx),
    Module:Function()
  end).

%% @doc Spawns a linked process with the current context propagated.
-spec spawn_link_with_context(fun(() -> term())) -> pid().
spawn_link_with_context(Fun) when is_function(Fun, 0) ->
  Ctx = current(),
  spawn_link(fun() ->
    _ = attach(Ctx),
    Fun()
  end).

%% @doc Spawns a linked process in a module with the current context propagated.
-spec spawn_link_with_context(module(), atom()) -> pid().
spawn_link_with_context(Module, Function) ->
  Ctx = current(),
  spawn_link(fun() ->
    _ = attach(Ctx),
    Module:Function()
  end).
