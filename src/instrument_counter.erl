%% Copyright (c) 2017, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_counter).

%% public api
-export([
  new/2,
  inc/1, inc/2,
  get/1,
  collect/2
]).

-include("instrument.hrl").


new(Name, Help) ->
  {ok, Ref} = instrument_nif:new_gauge(),
  Info = instrument_lib:mk_info(Name, Help),
  #metric{
    name=Name,
    handle=Ref,
    collect = {?MODULE, collect, [Info, Ref]}
  }.


inc(#metric{handle=Ref}) -> instrument_nif:inc_gauge(Ref).

inc(#metric{handle=Ref}, Val) when Val >= 0 -> instrument_nif:inc_gauge(Ref, float(Val));
inc(_, _) -> erlang:error(badarg).

get(#metric{handle=Ref}) -> instrument_nif:get_gauge(Ref).

collect(Info, Ref) ->
  #metric_info{name=Name, help=Help} = Info,
  #{ name => Name,
     help => Help,
     type => counter,
     val => instrument_nif:get_gauge(Ref)
  }.