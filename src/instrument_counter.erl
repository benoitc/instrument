%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Counter metric implementation with monotonically increasing semantics.
%%
%% A counter is a cumulative metric that can only increase. It is typically
%% used to count requests served, tasks completed, or errors occurred.
%%
%% Counters use NIF-based atomic operations for high-performance concurrent
%% updates without locks.
%%
%% == Example ==
%% ```
%% Counter = instrument_counter:new_counter(requests, <<"Total requests">>),
%% instrument_counter:inc_counter(Counter),      % Increment by 1
%% instrument_counter:inc_counter(Counter, 10),  % Increment by 10
%% Value = instrument_counter:get_counter(Counter).
%% '''
%%
%% @see instrument
-module(instrument_counter).

%% public api
-export([
  new_counter/2,
  inc_counter/1, inc_counter/2,
  get_counter/1,
  collect/2,
  with_counter/2, with_counter/3
]).

-include("instrument.hrl").


new_counter(Name, Help) ->
  {ok, Ref} = instrument_nif:new_gauge(),
  StartTime = erlang:system_time(nanosecond),
  Info = instrument_lib:mk_info(Name, Help),
  #metric{
    name=Name,
    handle={Ref, StartTime},
    collect = {?MODULE, collect, [Info, {Ref, StartTime}]}
  }.


inc_counter(#metric{handle={Ref, _}}) -> instrument_nif:inc_gauge(Ref).

inc_counter(#metric{handle={Ref, _}}, Val) when Val >= 0 -> instrument_nif:inc_gauge(Ref, float(Val));
inc_counter(_, _) -> erlang:error(badarg).

get_counter(#metric{handle={Ref, _}}) -> instrument_nif:get_gauge(Ref).

with_counter(Counter, F) -> with_counter_1(Counter, F, []).
with_counter(Counter, F, V) -> with_counter_1(Counter, F, [V]).
with_counter_1(Counter, F, A) ->
  instrument_registry:with(Counter, fun(M) -> erlang:apply(?MODULE, F, [M|A]) end).

collect(Info, {Ref, StartTime}) ->
  #metric_info{name=Name, help=Help} = Info,
  #{ name => Name,
     help => Help,
     type => counter,
     val => instrument_nif:get_gauge(Ref),
     start_time => StartTime
  }.