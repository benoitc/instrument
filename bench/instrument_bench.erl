%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Benchmarks for instrument library.
%%
%% Run with: rebar3 as bench shell --eval 'instrument_bench:run().'
%%
%% Or run specific benchmarks:
%%   instrument_bench:run_counter().
%%   instrument_bench:run_meter().
%%   instrument_bench:run_tracer().
%%   instrument_bench:run_logger().
-module(instrument_bench).
-author("benoitc").

-export([
    run/0,
    run_counter/0,
    run_gauge/0,
    run_histogram/0,
    run_meter/0,
    run_tracer/0,
    run_logger/0
]).

%% Internal exports for benchmarking
-export([
    bench/3,
    format_result/2
]).

-define(DEFAULT_ITERATIONS, 100000).
-define(WARMUP_ITERATIONS, 1000).

%% ============================================================================
%% Public API
%% ============================================================================

%% @doc Runs all benchmarks.
-spec run() -> ok.
run() ->
    io:format(user, "~n=== Instrument Benchmarks ===~n~n", []),
    {ok, _} = application:ensure_all_started(instrument),
    instrument_logger:install(),
    try
        run_counter(),
        io:format(user, "~n", []),
        run_gauge(),
        io:format(user, "~n", []),
        run_histogram(),
        io:format(user, "~n", []),
        run_meter(),
        io:format(user, "~n", []),
        run_tracer(),
        io:format(user, "~n", []),
        run_logger(),
        io:format(user, "~n=== Benchmarks Complete ===~n", [])
    after
        instrument_logger:uninstall()
    end,
    ok.

%% @doc Benchmark basic counter operations.
-spec run_counter() -> ok.
run_counter() ->
    io:format(user, "--- Counter Benchmarks ---~n", []),

    %% Create counter
    Counter = instrument_metric:new_counter(bench_counter, <<"Benchmark counter">>),

    %% Warmup
    warmup(fun() -> instrument_metric:inc_counter(Counter) end),

    %% Benchmark inc_counter/1
    R1 = bench("counter:inc_counter/1", ?DEFAULT_ITERATIONS, fun() ->
        instrument_metric:inc_counter(Counter)
    end),
    format_result("counter:inc_counter/1", R1),

    %% Benchmark inc_counter/2
    R2 = bench("counter:inc_counter/2", ?DEFAULT_ITERATIONS, fun() ->
        instrument_metric:inc_counter(Counter, 1)
    end),
    format_result("counter:inc_counter/2", R2),

    %% Benchmark get_counter/1
    R3 = bench("counter:get_counter/1", ?DEFAULT_ITERATIONS, fun() ->
        instrument_metric:get_counter(Counter)
    end),
    format_result("counter:get_counter/1", R3),

    %% Cleanup
    instrument_metric:unregister(bench_counter),
    ok.

%% @doc Benchmark basic gauge operations.
-spec run_gauge() -> ok.
run_gauge() ->
    io:format(user, "--- Gauge Benchmarks ---~n", []),

    %% Create gauge
    Gauge = instrument_metric:new_gauge(bench_gauge, <<"Benchmark gauge">>),

    %% Warmup
    warmup(fun() -> instrument_metric:set_gauge(Gauge, 100) end),

    %% Benchmark set_gauge/2
    R1 = bench("gauge:set_gauge/2", ?DEFAULT_ITERATIONS, fun() ->
        instrument_metric:set_gauge(Gauge, 100)
    end),
    format_result("gauge:set_gauge/2", R1),

    %% Benchmark inc_gauge/1
    R2 = bench("gauge:inc_gauge/1", ?DEFAULT_ITERATIONS, fun() ->
        instrument_metric:inc_gauge(Gauge)
    end),
    format_result("gauge:inc_gauge/1", R2),

    %% Benchmark dec_gauge/1
    R3 = bench("gauge:dec_gauge/1", ?DEFAULT_ITERATIONS, fun() ->
        instrument_metric:dec_gauge(Gauge)
    end),
    format_result("gauge:dec_gauge/1", R3),

    %% Benchmark get_gauge/1
    R4 = bench("gauge:get_gauge/1", ?DEFAULT_ITERATIONS, fun() ->
        instrument_metric:get_gauge(Gauge)
    end),
    format_result("gauge:get_gauge/1", R4),

    %% Cleanup
    instrument_metric:unregister(bench_gauge),
    ok.

%% @doc Benchmark basic histogram operations.
-spec run_histogram() -> ok.
run_histogram() ->
    io:format(user, "--- Histogram Benchmarks ---~n", []),

    %% Create histogram
    Histogram = instrument_metric:new_histogram(bench_histogram, <<"Benchmark histogram">>),

    %% Warmup
    warmup(fun() -> instrument_metric:observe_histogram(Histogram, 0.5) end),

    %% Benchmark observe_histogram/2
    R1 = bench("histogram:observe/2", ?DEFAULT_ITERATIONS, fun() ->
        instrument_metric:observe_histogram(Histogram, 0.125)
    end),
    format_result("histogram:observe/2", R1),

    %% Benchmark get_histogram/1
    R2 = bench("histogram:get/1", ?DEFAULT_ITERATIONS, fun() ->
        instrument_metric:get_histogram(Histogram)
    end),
    format_result("histogram:get/1", R2),

    %% Cleanup
    instrument_metric:unregister(bench_histogram),
    ok.

%% @doc Benchmark OpenTelemetry Meter API.
-spec run_meter() -> ok.
run_meter() ->
    io:format(user, "--- OTel Meter Benchmarks ---~n", []),

    %% Create meter and instruments
    Meter = instrument_meter:get_meter(<<"bench_service">>),
    Counter = instrument_meter:create_counter(Meter, <<"otel_bench_counter">>, #{
        description => <<"Benchmark counter">>
    }),
    Histogram = instrument_meter:create_histogram(Meter, <<"otel_bench_histogram">>, #{
        description => <<"Benchmark histogram">>
    }),
    Gauge = instrument_meter:create_gauge(Meter, <<"otel_bench_gauge">>, #{
        description => <<"Benchmark gauge">>
    }),

    %% Warmup
    warmup(fun() -> instrument_meter:add(Counter, 1) end),

    %% Benchmark meter:add/2 (counter without attributes)
    R1 = bench("meter:add/2", ?DEFAULT_ITERATIONS, fun() ->
        instrument_meter:add(Counter, 1)
    end),
    format_result("meter:add/2", R1),

    %% Benchmark meter:add/3 (counter with attributes)
    R2 = bench("meter:add/3 (attrs)", ?DEFAULT_ITERATIONS, fun() ->
        instrument_meter:add(Counter, 1, #{method => <<"GET">>, status => 200})
    end),
    format_result("meter:add/3 (attrs)", R2),

    %% Benchmark meter:record/2 (histogram without attributes)
    R3 = bench("meter:record/2", ?DEFAULT_ITERATIONS, fun() ->
        instrument_meter:record(Histogram, 0.125)
    end),
    format_result("meter:record/2", R3),

    %% Benchmark meter:record/3 (histogram with attributes)
    R4 = bench("meter:record/3 (attrs)", ?DEFAULT_ITERATIONS, fun() ->
        instrument_meter:record(Histogram, 0.125, #{endpoint => <<"/api">>})
    end),
    format_result("meter:record/3 (attrs)", R4),

    %% Benchmark meter:set/2 (gauge without attributes)
    R5 = bench("meter:set/2", ?DEFAULT_ITERATIONS, fun() ->
        instrument_meter:set(Gauge, 42)
    end),
    format_result("meter:set/2", R5),

    %% Cleanup
    instrument_meter:unregister_instrument(<<"otel_bench_counter">>),
    instrument_meter:unregister_instrument(<<"otel_bench_histogram">>),
    instrument_meter:unregister_instrument(<<"otel_bench_gauge">>),
    ok.

%% @doc Benchmark OpenTelemetry Tracer API.
-spec run_tracer() -> ok.
run_tracer() ->
    io:format(user, "--- OTel Tracer Benchmarks ---~n", []),

    %% Warmup
    warmup(fun() ->
        instrument_tracer:with_span(<<"warmup">>, fun() -> ok end)
    end),

    %% Benchmark with_span/2 (minimal span)
    R1 = bench("tracer:with_span/2", ?DEFAULT_ITERATIONS, fun() ->
        instrument_tracer:with_span(<<"bench_span">>, fun() -> ok end)
    end),
    format_result("tracer:with_span/2", R1),

    %% Benchmark with_span/3 with kind
    R2 = bench("tracer:with_span/3 (kind)", ?DEFAULT_ITERATIONS, fun() ->
        instrument_tracer:with_span(<<"bench_span">>, #{kind => server}, fun() -> ok end)
    end),
    format_result("tracer:with_span/3 (kind)", R2),

    %% Benchmark with_span + set_attributes
    R3 = bench("tracer:with_span + attrs", ?DEFAULT_ITERATIONS, fun() ->
        instrument_tracer:with_span(<<"bench_span">>, fun() ->
            instrument_tracer:set_attributes(#{
                <<"http.method">> => <<"GET">>,
                <<"http.status_code">> => 200
            })
        end)
    end),
    format_result("tracer:with_span + attrs", R3),

    %% Benchmark with_span + add_event
    R4 = bench("tracer:with_span + event", ?DEFAULT_ITERATIONS, fun() ->
        instrument_tracer:with_span(<<"bench_span">>, fun() ->
            instrument_tracer:add_event(<<"checkpoint">>)
        end)
    end),
    format_result("tracer:with_span + event", R4),

    %% Benchmark nested spans
    R5 = bench("tracer:nested spans (3)", ?DEFAULT_ITERATIONS div 10, fun() ->
        instrument_tracer:with_span(<<"outer">>, fun() ->
            instrument_tracer:with_span(<<"middle">>, fun() ->
                instrument_tracer:with_span(<<"inner">>, fun() -> ok end)
            end)
        end)
    end),
    format_result("tracer:nested spans (3)", R5),

    %% Benchmark start_span/end_span (manual)
    R6 = bench("tracer:start/end_span", ?DEFAULT_ITERATIONS, fun() ->
        Span = instrument_tracer:start_span(<<"bench_span">>),
        instrument_tracer:end_span(Span)
    end),
    format_result("tracer:start/end_span", R6),

    ok.

%% @doc Benchmark OpenTelemetry Logger integration.
-spec run_logger() -> ok.
run_logger() ->
    io:format(user, "--- OTel Logger Benchmarks ---~n", []),

    %% Suppress logger output during benchmark
    ok = logger:set_primary_config(level, none),

    try
        %% Benchmark logger:info outside span
        R1 = bench("logger:info (no span)", ?DEFAULT_ITERATIONS, fun() ->
            logger:info("Benchmark message")
        end),
        format_result("logger:info (no span)", R1),

        %% Benchmark logger:info inside span (trace context added)
        instrument_tracer:with_span(<<"logger_bench">>, fun() ->
            R2 = bench("logger:info (in span)", ?DEFAULT_ITERATIONS, fun() ->
                logger:info("Benchmark message")
            end),
            format_result("logger:info (in span)", R2)
        end),

        %% Benchmark logger:info with metadata
        R3 = bench("logger:info (metadata)", ?DEFAULT_ITERATIONS, fun() ->
            logger:info("Benchmark message", #{user_id => 123, request_id => <<"abc">>})
        end),
        format_result("logger:info (metadata)", R3),

        %% Benchmark instrument_logger:emit
        instrument_tracer:with_span(<<"emit_bench">>, fun() ->
            R4 = bench("instrument_logger:emit", ?DEFAULT_ITERATIONS, fun() ->
                instrument_logger:emit(<<"Benchmark message">>)
            end),
            format_result("instrument_logger:emit", R4)
        end)
    after
        %% Restore logger level
        ok = logger:set_primary_config(level, info)
    end,
    ok.

%% ============================================================================
%% Internal Functions
%% ============================================================================

warmup(Fun) ->
    lists:foreach(fun(_) -> Fun() end, lists:seq(1, ?WARMUP_ITERATIONS)).

%% @doc Run a benchmark.
%% Returns {TotalTimeNs, Iterations, OpsPerSec, AvgTimeNs}
-spec bench(string(), pos_integer(), fun(() -> any())) ->
    {non_neg_integer(), pos_integer(), float(), float()}.
bench(_Name, Iterations, Fun) ->
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
    %% Pad name to 32 chars
    PaddedName = string:pad(Name, 32, trailing),
    %% Format numbers
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
