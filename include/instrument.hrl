-record(metric, {
  name,
  handle :: term(),
  collect :: tuple()
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