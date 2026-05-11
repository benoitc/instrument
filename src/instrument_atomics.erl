%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Pure-Erlang atomic slots backing the histogram bucket counts and sum.
%%
%% Thin wrapper over the OTP `atomics' module providing both signed-integer
%% slots (`inc_int_at'/`get_int_at') and IEEE-754 double slots via bit-cast
%% with a CAS retry loop (`inc_at'/`set_at'/`get_at').
%%
%% Slots are 1-indexed, matching `atomics'.
-module(instrument_atomics).

-export([
  new/1,
  inc_at/3,
  set_at/3,
  get_at/2,
  inc_int_at/3,
  get_int_at/2
]).

%% @doc Allocate an N-slot atomics ref. Caller decides slot semantics.
new(N) when is_integer(N), N >= 1 ->
  atomics:new(N, [{signed, true}]).

%% --- float slots (bit-cast into signed int64 with CAS retry) ---

set_at(Ref, Ix, V) when is_float(V) ->
  <<Bits:64/integer-signed>> = <<V/float>>,
  atomics:put(Ref, Ix, Bits);
set_at(Ref, Ix, V) when is_integer(V) ->
  set_at(Ref, Ix, float(V)).

get_at(Ref, Ix) ->
  Bits = atomics:get(Ref, Ix),
  <<F/float>> = <<Bits:64/integer-signed>>,
  F.

inc_at(Ref, Ix, Delta) ->
  inc_at_loop(Ref, Ix, float(Delta), atomics:get(Ref, Ix)).

inc_at_loop(Ref, Ix, Delta, Old) ->
  <<F/float>> = <<Old:64/integer-signed>>,
  <<New:64/integer-signed>> = <<(F + Delta)/float>>,
  case atomics:compare_exchange(Ref, Ix, Old, New) of
    ok -> ok;
    Actual -> inc_at_loop(Ref, Ix, Delta, Actual)
  end.

%% --- integer slots ---

inc_int_at(Ref, Ix, V) when is_integer(V) -> atomics:add(Ref, Ix, V).

get_int_at(Ref, Ix) -> atomics:get(Ref, Ix).
