# Migrating to 2.0

This page covers what changes for you when you upgrade from 1.x to 2.0. Read it before upgrading if you query labeled meter metrics by name, rely on the cardinality limit, or call registry internals directly. Unlabeled metrics and the Prometheus-style simple API (`new_counter/2`, `inc_counter/1`, and so on) behave as before.

## Update queries for labeled meter metrics

In 1.x, a meter instrument written with attributes was exported under a name built from the attribute keys. In 2.0 it is exported under its own name, with the attributes as labels.

```erlang
Counter = instrument_meter:create_counter(Meter, <<"requests">>),
instrument_meter:add(Counter, 1, #{method => <<"GET">>, status => 200}).
```

```
# 1.x
requests_method_status_total 1.0

# 2.0
requests_total{method="GET",status="200"} 1.0
```

To migrate:

1. List the dashboards, recording rules and alerts that use names of the form `<name>_<key>_<key>`.
2. Replace each one with the instrument name plus a label selector, for example `requests_method_status_total` becomes `requests_total`, and aggregate with `sum by (method, status)`.
3. If the same instrument was written with different sets of attribute keys, those series are now one metric. A label missing from a given write is exported as an empty value.

Histograms follow the same rule (`latency_bucket{route="/x",le="0.1"}` instead of `latency_route_bucket{le="0.1"}`).

## Expect no series before the first write

A meter instrument no longer exports a `0` value from the moment it is created. It appears on its first write.

If an alert relies on the series existing (for example `absent(requests_total)`), write an initial value at startup:

```erlang
instrument_meter:add(Counter, 0).
```

Simple-API metrics (`instrument_metric:new_counter/2`, `new_gauge/2`, `new_histogram/2,3`) still appear as soon as they are created.

## Check the cardinality limit

The limit (`OTEL_METRIC_CARDINALITY_LIMIT`, default 2000) now applies to each metric as a whole. In 1.x each combination of attribute keys under one instrument had its own limit.

If one instrument is written with several attribute key sets, it now reaches the limit sooner. Raise the limit if needed:

```sh
export OTEL_METRIC_CARDINALITY_LIMIT=5000
```

Writes over the limit go to one overflow series, as before. For meter instruments it carries `otel.metric.overflow="true"`; for vector metrics every declared label is set to `otel.metric.overflow`. Read the number of dropped label sets with:

```erlang
instrument_registry:cardinality_dropped(Name).
```

## Don't call formatters from observable callbacks

`instrument_prometheus:format/0` and the OTLP exporter now run observable callbacks themselves before collecting. A callback that calls either of them recurses forever. Read your source data directly in the callback instead.

## Replace removed functions

These internal functions are gone. If you called them, switch to the public API:

| Removed | Use instead |
|---|---|
| `instrument_registry:lookup_label`, `cache_label`, `create_vector_metric` | `instrument_metric:with_label/3,4` or `instrument_vector:get_or_create_label/2` |
| `instrument_registry:get_or_create_overflow` | `instrument_registry:overflow_sentinel/1` |
| `instrument_lib:table`, `tables` | nothing; the per-scheduler tables no longer exist |
| `instrument_vector:collect` | `instrument_registry:collect_all/0` |

`instrument_registry:lookup/1` still exists but returns metric metadata instead of the internal `#metric{}` record. Treat its result as opaque.

## Notes

- Upgrading a running node in place from 1.x cleans the old internal state when the registry starts.
- Labeled writes are more than twice as fast. Unlabeled meter writes take about 21 ns instead of 15 ns; the simple API (`instrument_metric:new_counter/2` and `inc_counter/1`) stays at about 20 ns. See [Benchmarks](benchmarks.md).
