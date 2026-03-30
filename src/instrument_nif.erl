%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_nif).

-export([
  new_gauge/0,
  inc_gauge/1, inc_gauge/2,
  dec_gauge/1, dec_gauge/2,
  set_gauge/2,
  get_gauge/1,
  destroy_gauge/1
]).

-on_load(init/0).

init() ->
  SoName = case code:priv_dir(?MODULE) of
                 {error, bad_name} ->
                     case code:which(?MODULE) of
                         Filename when is_list(Filename) ->
                             filename:join([filename:dirname(Filename),"../priv", "instrument_nif"]);
                         _ ->
                             filename:join("../priv", "instrument_nif")
                     end;
                 Dir ->
                     filename:join(Dir, "instrument_nif")
             end,
    erlang:load_nif(SoName, application:get_all_env(instrument_nif)).

new_gauge() ->
  erlang:nif_error({error, not_loaded}).

inc_gauge(_Gauge) ->
  erlang:nif_error({error, not_loaded}).

inc_gauge(_Gauge, _V) ->
  erlang:nif_error({error, not_loaded}).

dec_gauge(_Gauge) ->
  erlang:nif_error({error, not_loaded}).

dec_gauge(_Gauge, _V)  ->
  erlang:nif_error({error, not_loaded}).

set_gauge(_Gauge, _V) ->
  erlang:nif_error({error, not_loaded}).

get_gauge(_Gauge) ->
  erlang:nif_error({error, not_loaded}).

destroy_gauge(_Gauge) ->
  erlang:nif_error({error, not_loaded}).