%% Copyright (c) 2017, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_lib).
-author("benoitc").

%% API
-export([
  mk_info/2,
  apply_fun/2
]).

-include("instrument.hrl").

mk_info(Name, Help) ->
  #metric_info{name=Name, help=Help}.

apply_fun(F, M) when is_function(F) ->
  F(M);
apply_fun({F, Args}, M) when is_function(F), is_list(Args) ->
  erlang:apply(F, [M | Args]);
apply_fun({Mod, F}, M) when is_atom(M), is_function(F) ->
  erlang:apply(Mod, F, [M]);
apply_fun({Mod, F, Args}, M) when is_atom(Mod), is_function(F), is_list(Args) ->
  erlang:apply(Mod, F, [M | Args]).