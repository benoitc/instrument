%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-record(metric, {
  name,
  handle :: term(),
  collect :: tuple(),
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

%% Series-store family metadata. Stored once in persistent_term
%% {instrument_family, Name} and (as the recoverable copy) in the
%% instrument_series arbiter row {{Name, family}, Meta}. Never replaced on any
%% designed path; clear_labels replaces it (admin-time) to re-mint the chain.
-record(family, {
  kind            :: counter | up_down_counter | gauge | histogram
                   | observable_counter | observable_gauge
                   | observable_up_down_counter,
  help = <<>>     :: binary(),
  declared_labels :: [term()] | undefined,   %% vec API: declared names; meter: undefined
  boundaries      :: [number()] | undefined, %% histograms only
  start_time      :: integer(),              %% creation ns
  idx             :: pos_integer(),          %% slot in the family chain
  row_seq         :: atomics:atomics_ref()   %% mints row slot numbers
}).
