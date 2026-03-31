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


-record(vector, {
  name,
  help,
  metric,
  buckets = [],
  labels = [],
  labels_map = #{}
}).