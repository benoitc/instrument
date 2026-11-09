%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-record(metric, {
  name,
  handle :: term(),
  collect :: tuple() | undefined,
  %% OTel fields (optional)
  description :: binary() | undefined,
  unit :: binary() | undefined,
  meter :: binary() | undefined,
  attributes = #{} :: map()
}).

-record(metric_info, {
  name,
  help
}).

%% Series-store family metadata, published once in persistent_term
%% {instrument_family, Name} and kept in the instrument_series arbiter row
%% {{Name, family}, Meta}. Never replaced on a designed path.
%%
%% Series live in pre-created slots. Slot 1 is reserved for the unlabeled
%% series. Slots come in chunks of growing size (16, 32, ... 1024): chunk 0 is
%% stored here, later chunks under {instrument_chunk, Name, Inc, C}. A chunk
%% is {Epochs, Rows}: one epoch per slot in an atomics array (odd = live) and
%% a tuple of pre-minted #metric{} cells.
-record(family, {
  kind            :: counter | up_down_counter | gauge | histogram
                   | observable_counter | observable_gauge
                   | observable_up_down_counter,
  help = <<>>     :: binary(),
  declared_labels :: [term()] | undefined,   %% vec API: declared names; meter: undefined
  boundaries      :: [number()] | undefined, %% histograms only
  start_time      :: integer(),              %% creation ns
  idx             :: pos_integer(),          %% slot in the family chain
  inc             :: pos_integer(),          %% unique per incarnation
  counters        :: atomics:atomics_ref(),  %% high-water, live, dropped, aliases
  chunk0          :: {atomics:atomics_ref(), tuple()}
}).
