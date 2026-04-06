%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Gauge metric implementation for point-in-time measurements.
%%
%% A gauge represents a single numerical value that can arbitrarily go up
%% and down. Gauges are typically used for measured values like temperature,
%% current memory usage, or the number of concurrent requests.
%%
%% Gauges use NIF-based atomic operations for high-performance concurrent
%% updates without locks.
%%
%% == Example ==
%% ```
%% Gauge = instrument_gauge:new_gauge(temperature, <<"Current temperature">>),
%% instrument_gauge:set_gauge(Gauge, 23.5),       % Set to specific value
%% instrument_gauge:inc_gauge(Gauge),             % Increment by 1
%% instrument_gauge:dec_gauge(Gauge, 0.5),        % Decrement by 0.5
%% Value = instrument_gauge:get_gauge(Gauge).
%% '''
%%
%% @see instrument
-module(instrument_gauge).

%% public api
-export([
  new_gauge/2,
  inc_gauge/1, inc_gauge/2,
  dec_gauge/1, dec_gauge/2,
  set_gauge/2,
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