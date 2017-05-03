%% Copyright (c) 2017, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_gauge).

%% public api
-export([
  new_gauge/2,
  inc_gauge/1, inc_gauge/2,
  dec_gauge/1, dec_gauge/2,
  set_gauge/2,
  set_gauge_to_current_time/1,
  get_gauge/1,
  collect/2,
  with_gauge/2, with_gauge/3
]).

-include("instrument.hrl").


new_gauge(Name, Help) ->
  {ok, Ref} = instrument_nif:new_gauge(),
  Info = instrument_lib:mk_info(Name, Help),
  #metric{
    name=Name,
    handle=Ref,
    collect = {?MODULE, collect, [Info, Ref]}
  }.


inc_gauge(#metric{handle=Ref}) -> instrument_nif:inc_gauge(Ref).

inc_gauge(#metric{handle=Ref}, Val) when Val >= 0 -> instrument_nif:inc_gauge(Ref, float(Val));
inc_gauge(_, _) -> erlang:error(badarg).

dec_gauge(#metric{handle=Ref}) -> instrument_nif:dec_gauge(Ref).

dec_gauge(#metric{handle=Ref}, Val) when Val >= 0 -> instrument_nif:dec_gauge(Ref, float(Val));
dec_gauge(_, _) -> erlang:error(badarg).

set_gauge(#metric{handle=Ref}, Val) -> instrument_nif:set_gauge(Ref, float(Val));
set_gauge(_, _) -> erlang:error(badarg).

set_gauge_to_current_time(M) ->
  Time = erlang:monotonic_time(second),
  set_gauge(M, Time).
 
get_gauge(#metric{handle=Ref}) -> instrument_nif:get_gauge(Ref).

with_gauge(Gauge, F) -> with_gauge_1(Gauge, F, []).
with_gauge(Gauge, F, V) -> with_gauge_1(Gauge, F, [V]).
with_gauge_1(Gauge, F, A) ->
  instrument_registry:with(Gauge, fun(M) -> erlang:apply(?MODULE, F, [M|A]) end).


collect(Info, Ref) ->
  #metric_info{name=Name, help=Help} = Info,
  #{name => Name,
    help => Help,
    type => gauge,
    val => instrument_nif:get_gauge(Ref)
  }.