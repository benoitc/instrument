%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_lib).
-author("benoitc").

%% API
-export([
  mk_info/2
]).

-include("instrument.hrl").

mk_info(Name, Help) ->
  #metric_info{name=Name, help=Help}.
