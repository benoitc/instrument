%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Real-world usage scenario benchmarks for instrument library.
%%
%% These benchmarks simulate realistic instrumentation patterns:
%% - Database query tracing with metrics
%% - HTTP request pipeline with nested spans
%% - Concurrent load simulation
%% - Memory/GC impact measurement
%%
%% Run with: rebar3 as bench shell --eval 'instrument_realworld_bench:run().'
%%
%% Or run specific scenarios:
%%   instrument_realworld_bench:run_db_tracing().
%%   instrument_realworld_bench:run_http_pipeline().
%%   instrument_realworld_bench:run_concurrent_load().
%%   instrument_realworld_bench:run_concurrent_load(200, 5000).
%%   instrument_realworld_bench:run_memory_impact().
-module(instrument_realworld_bench).
-author("benoitc").

-export([
    run/0,
    run_db_tracing/0,
    run_http_pipeline/0,
    run_concurrent_load/0,
    run_concurrent_load/2,
    run_memory_impact/0
]).

-define(DEFAULT_DB_ITERATIONS, 10000).
-define(DEFAULT_HTTP_ITERATIONS, 5000).
-define(DEFAULT_WORKERS, 100).
-define(DEFAULT_REQUESTS_PER_WORKER, 1000).
-define(MEMORY_ITERATIONS, 100000).
-define(WARMUP_ITERATIONS, 100).

%% ============================================================================
%% Public API
%% ============================================================================

%% @doc Runs all real-world benchmarks.
-spec run() -> ok.
run() ->
    io:format(user, "~n=== Real-World Scenario Benchmarks ===~n~n", []),
    {ok, _} = application:ensure_all_started(instrument),
    try
        run_db_tracing(),
        io:format(user, "~n", []),
        run_http_pipeline(),
        io:format(user, "~n", []),
        run_concurrent_load(),
        io:format(user, "~n", []),
        run_memory_impact(),
        io:format(user, "~n=== Real-World Benchmarks Complete ===~n", [])
    after
        ok
    end,
    ok.

%% @doc Benchmark database query tracing with metrics.
%%
%% Simulates tracing database queries with:
%% - Span with DB semantic convention attributes
%% - Query duration histogram
%% - Query counter with labels
-spec run_db_tracing() -> ok.
run_db_tracing() ->
    {ok, _} = application:ensure_all_started(instrument),
    io:format(user, "--- DB Query Tracing Benchmark ---~n", []),
    io:format(user, "  Scenario: Trace DB query with attributes + record metrics~n", []),

    %% Setup metrics
    instrument_metric:new_histogram_vec(bench_db_query_duration, <<"DB query duration">>,
                                 [operation], [0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1.0]),
    instrument_metric:new_counter_vec(bench_db_queries_total, <<"Total DB queries">>,
                               [operation, table, status]),

    %% Warmup
    warmup(fun() -> db_query_traced() end),

    %% Benchmark: traced DB query with metrics
    {TotalNs, Iterations, OpsPerSec, AvgNs} = bench(?DEFAULT_DB_ITERATIONS, fun() ->
        db_query_traced()
    end),
    format_result("db_query_traced", {TotalNs, Iterations, OpsPerSec, AvgNs}),

    %% Benchmark: same without tracing (baseline)
    {TotalNs2, Iterations2, OpsPerSec2, AvgNs2} = bench(?DEFAULT_DB_ITERATIONS, fun() ->
        db_query_metrics_only()
    end),
    format_result("db_query_metrics_only", {TotalNs2, Iterations2, OpsPerSec2, AvgNs2}),

    %% Calculate overhead
    Overhead = (AvgNs - AvgNs2) / 1000,
    io:format(user, "  Tracing overhead: ~.3f us/op~n", [Overhead]),

    %% Cleanup
    instrument_metric:unregister(bench_db_query_duration),
    instrument_metric:unregister(bench_db_queries_total),
    ok.

db_query_traced() ->
    instrument_tracer:with_span(<<"db.query">>, #{kind => client}, fun() ->
        %% Set DB attributes (OTel semantic conventions)
        instrument_tracer:set_attributes(#{
            <<"db.system">> => <<"postgresql">>,
            <<"db.name">> => <<"mydb">>,
            <<"db.statement">> => <<"SELECT * FROM users WHERE id = $1">>,
            <<"db.operation">> => <<"SELECT">>,
            <<"db.sql.table">> => <<"users">>
        }),
        %% Record metrics
        Duration = rand:uniform() * 0.05,
        instrument_metric:observe_histogram_vec(bench_db_query_duration, [<<"SELECT">>], Duration),
        instrument_metric:inc_counter_vec(bench_db_queries_total, [<<"SELECT">>, <<"users">>, <<"ok">>])
    end).

db_query_metrics_only() ->
    Duration = rand:uniform() * 0.05,
    instrument_metric:observe_histogram_vec(bench_db_query_duration, [<<"SELECT">>], Duration),
    instrument_metric:inc_counter_vec(bench_db_queries_total, [<<"SELECT">>, <<"users">>, <<"ok">>]).

%% @doc Benchmark HTTP request pipeline with nested spans.
%%
%% Simulates: HTTP request -> Auth -> DB -> Response
-spec run_http_pipeline() -> ok.
run_http_pipeline() ->
    {ok, _} = application:ensure_all_started(instrument),
    io:format(user, "--- HTTP Request Pipeline Benchmark ---~n", []),
    io:format(user, "  Scenario: HTTP request -> Auth verify -> DB query -> Response~n", []),

    %% Setup metrics
    instrument_metric:new_histogram_vec(bench_http_request_duration, <<"HTTP request duration">>,
                                 [method, status], [0.01, 0.05, 0.1, 0.5, 1.0, 5.0]),
    instrument_metric:new_counter_vec(bench_http_requests_total, <<"Total HTTP requests">>,
                               [method, endpoint, status]),

    %% Warmup
    warmup(fun() -> http_pipeline_traced() end),

    %% Benchmark: full pipeline with nested spans
    {TotalNs, Iterations, OpsPerSec, AvgNs} = bench(?DEFAULT_HTTP_ITERATIONS, fun() ->
        http_pipeline_traced()
    end),
    format_result("http_pipeline (3 spans)", {TotalNs, Iterations, OpsPerSec, AvgNs}),

    %% Benchmark: flat (single span)
    {TotalNs2, Iterations2, OpsPerSec2, AvgNs2} = bench(?DEFAULT_HTTP_ITERATIONS, fun() ->
        http_pipeline_flat()
    end),
    format_result("http_pipeline (1 span)", {TotalNs2, Iterations2, OpsPerSec2, AvgNs2}),

    %% Benchmark: no tracing
    {TotalNs3, Iterations3, OpsPerSec3, AvgNs3} = bench(?DEFAULT_HTTP_ITERATIONS, fun() ->
        http_pipeline_metrics_only()
    end),
    format_result("http_pipeline (no trace)", {TotalNs3, Iterations3, OpsPerSec3, AvgNs3}),

    %% Calculate overheads
    NestedOverhead = (AvgNs - AvgNs3) / 1000,
    FlatOverhead = (AvgNs2 - AvgNs3) / 1000,
    io:format(user, "  Nested spans overhead: ~.3f us/op~n", [NestedOverhead]),
    io:format(user, "  Single span overhead: ~.3f us/op~n", [FlatOverhead]),

    %% Cleanup
    instrument_metric:unregister(bench_http_request_duration),
    instrument_metric:unregister(bench_http_requests_total),
    ok.

http_pipeline_traced() ->
    instrument_tracer:with_span(<<"http.request">>, #{kind => server}, fun() ->
        instrument_tracer:set_attributes(#{
            <<"http.method">> => <<"GET">>,
            <<"http.url">> => <<"/api/users/123">>,
            <<"http.flavor">> => <<"1.1">>
        }),

        %% Auth check span
        instrument_tracer:with_span(<<"auth.verify">>, #{kind => internal}, fun() ->
            instrument_tracer:set_attribute(<<"auth.type">>, <<"jwt">>),
            ok
        end),

        %% DB query span
        instrument_tracer:with_span(<<"db.query">>, #{kind => client}, fun() ->
            instrument_tracer:set_attributes(#{
                <<"db.system">> => <<"postgresql">>,
                <<"db.statement">> => <<"SELECT * FROM users WHERE id = $1">>
            }),
            ok
        end),

        %% Set response attributes and record metrics
        instrument_tracer:set_attributes(#{
            <<"http.status_code">> => 200,
            <<"http.response_content_length">> => 1024
        }),
        instrument_tracer:set_status(ok),

        Duration = rand:uniform() * 0.1,
        instrument_metric:observe_histogram_vec(bench_http_request_duration, [<<"GET">>, <<"200">>], Duration),
        instrument_metric:inc_counter_vec(bench_http_requests_total, [<<"GET">>, <<"/api/users">>, <<"200">>])
    end).

http_pipeline_flat() ->
    instrument_tracer:with_span(<<"http.request">>, #{kind => server}, fun() ->
        instrument_tracer:set_attributes(#{
            <<"http.method">> => <<"GET">>,
            <<"http.url">> => <<"/api/users/123">>,
            <<"http.flavor">> => <<"1.1">>,
            <<"auth.type">> => <<"jwt">>,
            <<"db.system">> => <<"postgresql">>,
            <<"db.statement">> => <<"SELECT * FROM users WHERE id = $1">>,
            <<"http.status_code">> => 200,
            <<"http.response_content_length">> => 1024
        }),
        instrument_tracer:set_status(ok),

        Duration = rand:uniform() * 0.1,
        instrument_metric:observe_histogram_vec(bench_http_request_duration, [<<"GET">>, <<"200">>], Duration),
        instrument_metric:inc_counter_vec(bench_http_requests_total, [<<"GET">>, <<"/api/users">>, <<"200">>])
    end).

http_pipeline_metrics_only() ->
    Duration = rand:uniform() * 0.1,
    instrument_metric:observe_histogram_vec(bench_http_request_duration, [<<"GET">>, <<"200">>], Duration),
    instrument_metric:inc_counter_vec(bench_http_requests_total, [<<"GET">>, <<"/api/users">>, <<"200">>]).

%% @doc Benchmark concurrent load with default parameters.
-spec run_concurrent_load() -> ok.
run_concurrent_load() ->
    run_concurrent_load(?DEFAULT_WORKERS, ?DEFAULT_REQUESTS_PER_WORKER).

%% @doc Benchmark concurrent load with custom parameters.
%%
%% Simulates N concurrent workers making requests with tracing and metrics.
-spec run_concurrent_load(NumWorkers :: pos_integer(), RequestsPerWorker :: pos_integer()) -> ok.
run_concurrent_load(NumWorkers, RequestsPerWorker) ->
    {ok, _} = application:ensure_all_started(instrument),
    io:format(user, "--- Concurrent Load Benchmark ---~n", []),
    io:format(user, "  Scenario: ~p workers x ~p requests = ~p total~n",
              [NumWorkers, RequestsPerWorker, NumWorkers * RequestsPerWorker]),

    %% Setup metrics
    instrument_metric:new_histogram_vec(bench_concurrent_request_duration, <<"Request duration">>,
                                 [endpoint], [0.01, 0.05, 0.1, 0.5, 1.0]),
    instrument_metric:new_counter_vec(bench_concurrent_requests_total, <<"Total requests">>,
                               [endpoint, status]),
    ActiveGauge = instrument_metric:new_gauge(bench_active_requests, <<"Active concurrent requests">>),

    Endpoints = [<<"/api/users">>, <<"/api/orders">>, <<"/api/products">>,
                 <<"/health">>, <<"/metrics">>],

    Parent = self(),
    Start = erlang:monotonic_time(millisecond),

    %% Spawn workers
    Pids = [spawn_link(fun() ->
        worker_loop(RequestsPerWorker, Endpoints, ActiveGauge),
        Parent ! {done, self()}
    end) || _ <- lists:seq(1, NumWorkers)],

    %% Wait for all workers
    lists:foreach(fun(Pid) ->
        receive {done, Pid} -> ok end
    end, Pids),

    End = erlang:monotonic_time(millisecond),

    TotalRequests = NumWorkers * RequestsPerWorker,
    ElapsedMs = End - Start,
    ElapsedSec = ElapsedMs / 1000,
    ReqPerSec = TotalRequests / ElapsedSec,

    ElapsedStr = float_to_list(ElapsedSec, [{decimals, 2}]),
    ReqPerSecStr = float_to_list(ReqPerSec, [{decimals, 0}]),
    io:format(user, "  Results: ~p requests in ~s sec = ~s req/sec~n",
              [TotalRequests, ElapsedStr, ReqPerSecStr]),

    %% Verify active requests gauge is back to 0
    FinalActive = instrument_metric:get_gauge(ActiveGauge),
    io:format(user, "  Active requests at end: ~p (should be 0)~n", [FinalActive]),

    %% Cleanup
    instrument_metric:unregister(bench_concurrent_request_duration),
    instrument_metric:unregister(bench_concurrent_requests_total),
    instrument_metric:unregister(bench_active_requests),
    ok.

worker_loop(0, _Endpoints, _ActiveGauge) ->
    ok;
worker_loop(N, Endpoints, ActiveGauge) ->
    instrument_metric:inc_gauge(ActiveGauge),
    try
        Endpoint = lists:nth(rand:uniform(length(Endpoints)), Endpoints),
        instrument_tracer:with_span(<<"http.request">>, #{kind => server}, fun() ->
            instrument_tracer:set_attributes(#{
                <<"http.method">> => <<"GET">>,
                <<"http.url">> => Endpoint
            }),
            Duration = rand:uniform() * 0.1,
            instrument_metric:observe_histogram_vec(bench_concurrent_request_duration, [Endpoint], Duration),
            instrument_metric:inc_counter_vec(bench_concurrent_requests_total, [Endpoint, <<"200">>]),
            instrument_tracer:set_status(ok)
        end)
    after
        instrument_metric:dec_gauge(ActiveGauge)
    end,
    worker_loop(N - 1, Endpoints, ActiveGauge).

%% @doc Benchmark memory and GC impact under sustained tracing load.
-spec run_memory_impact() -> ok.
run_memory_impact() ->
    {ok, _} = application:ensure_all_started(instrument),
    io:format(user, "--- Memory/GC Impact Benchmark ---~n", []),
    io:format(user, "  Scenario: ~p spans with attributes and events~n", [?MEMORY_ITERATIONS]),

    %% Force initial GC and capture baseline
    erlang:garbage_collect(),
    {memory, Mem0} = erlang:process_info(self(), memory),
    {garbage_collection, GC0} = erlang:process_info(self(), garbage_collection),
    MinorGC0 = proplists:get_value(minor_gcs, GC0, 0),

    Start = erlang:monotonic_time(millisecond),

    %% Run sustained tracing
    lists:foreach(fun(_) ->
        instrument_tracer:with_span(<<"memory_test">>, fun() ->
            instrument_tracer:set_attributes(#{
                <<"key1">> => <<"value1">>,
                <<"key2">> => 12345,
                <<"key3">> => 3.14159
            }),
            instrument_tracer:add_event(<<"checkpoint">>, #{<<"data">> => <<"test">>})
        end)
    end, lists:seq(1, ?MEMORY_ITERATIONS)),

    End = erlang:monotonic_time(millisecond),
    ElapsedMs = End - Start,

    %% Force GC and capture post-run stats
    erlang:garbage_collect(),
    {memory, Mem1} = erlang:process_info(self(), memory),
    {garbage_collection, GC1} = erlang:process_info(self(), garbage_collection),
    MinorGC1 = proplists:get_value(minor_gcs, GC1, 0),

    %% Results
    MemDelta = Mem1 - Mem0,
    GCRuns = MinorGC1 - MinorGC0,
    SpansPerSec = ?MEMORY_ITERATIONS / (ElapsedMs / 1000),
    MemPerSpan = abs(MemDelta) / ?MEMORY_ITERATIONS,

    SpansPerSecStr = float_to_list(SpansPerSec, [{decimals, 0}]),
    MemPerSpanStr = float_to_list(MemPerSpan, [{decimals, 1}]),
    io:format(user, "  Throughput: ~s spans/sec~n", [SpansPerSecStr]),
    io:format(user, "  Memory delta: ~p bytes (~s bytes/span)~n", [MemDelta, MemPerSpanStr]),
    io:format(user, "  Minor GC runs: ~p -> ~p (delta: ~p)~n", [MinorGC0, MinorGC1, GCRuns]),
    ok.

%% ============================================================================
%% Internal Functions
%% ============================================================================

warmup(Fun) ->
    lists:foreach(fun(_) -> Fun() end, lists:seq(1, ?WARMUP_ITERATIONS)).

%% @doc Run a benchmark and return results.
-spec bench(pos_integer(), fun(() -> any())) ->
    {non_neg_integer(), pos_integer(), float(), float()}.
bench(Iterations, Fun) ->
    %% Force GC before benchmark
    erlang:garbage_collect(),

    %% Run benchmark
    Start = erlang:monotonic_time(nanosecond),
    run_iterations(Fun, Iterations),
    End = erlang:monotonic_time(nanosecond),

    %% Calculate results
    TotalTimeNs = End - Start,
    TotalTimeSec = TotalTimeNs / 1_000_000_000,
    OpsPerSec = Iterations / TotalTimeSec,
    AvgTimeNs = TotalTimeNs / Iterations,

    {TotalTimeNs, Iterations, OpsPerSec, AvgTimeNs}.

run_iterations(_Fun, 0) ->
    ok;
run_iterations(Fun, N) ->
    Fun(),
    run_iterations(Fun, N - 1).

%% @doc Format and print benchmark result.
-spec format_result(string(), {non_neg_integer(), pos_integer(), float(), float()}) -> ok.
format_result(Name, {_TotalTimeNs, Iterations, OpsPerSec, AvgTimeNs}) ->
    AvgTimeUs = AvgTimeNs / 1000,
    PaddedName = string:pad(Name, 28, trailing),
    OpsStr = integer_to_list(Iterations),
    OpsSecStr = format_number(OpsPerSec),
    AvgStr = float_to_list(AvgTimeUs, [{decimals, 3}]),
    Line = ["  ", PaddedName, " ", OpsStr, " ops  ", OpsSecStr, " ops/sec  ", AvgStr, " us/op\n"],
    io:put_chars(user, Line).

format_number(N) when N >= 1000000 ->
    float_to_list(N / 1000000, [{decimals, 2}]) ++ "M";
format_number(N) when N >= 1000 ->
    float_to_list(N / 1000, [{decimals, 2}]) ++ "K";
format_number(N) ->
    float_to_list(N, [{decimals, 0}]).
