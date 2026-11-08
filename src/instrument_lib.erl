%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_lib).
-author("benoitc").

%% API
-export([
  mk_info/2,
  safe_call/1,
  safe_call/2,
  safe_apply/4,
  bounded_env/4
]).

-include("instrument.hrl").

mk_info(Name, Help) ->
  #metric_info{name=Name, help=Help}.


%% @doc Run a 0-arity fun, ignoring any exception. Returns `ok' on failure.
-spec safe_call(fun(() -> term())) -> term().
safe_call(Fun) ->
  safe_call(Fun, ok).

%% @doc Run a 0-arity fun, returning `Default' on any exception.
-spec safe_call(fun(() -> term()), term()) -> term().
safe_call(Fun, Default) when is_function(Fun, 0) ->
  try Fun() catch _:_ -> Default end.

%% @doc Best-effort apply/3, returning `Default' on any exception.
-spec safe_apply(module(), atom(), [term()], term()) -> term().
safe_apply(M, F, A, Default) ->
  try apply(M, F, A) catch _:_ -> Default end.


%% @doc Reads an integer from the `instrument' application env, accepting
%% values in `[Min, Max]'. Returns `Default' when the key is unset; logs a
%% warning and returns `Default' when the value is out of range or not an
%% integer.
-spec bounded_env(atom(), integer(), integer(), integer()) -> integer().
bounded_env(Key, Default, Min, Max) ->
  case application:get_env(instrument, Key) of
    undefined -> Default;
    {ok, V} when is_integer(V), V >= Min, V =< Max -> V;
    {ok, Bad} ->
      logger:warning("instrument: ignoring invalid ~p value ~p, using ~p",
                     [Key, Bad, Default]),
      Default
  end.
