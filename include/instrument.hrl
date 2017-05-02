-record(metric, {
  name,
  handle :: term(),
  collect :: tuple()
}).

-record(metric_info, {
  name,
  help
}).