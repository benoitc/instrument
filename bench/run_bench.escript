#!/usr/bin/env escript
%% -*- erlang -*-
%%! -pa _build/bench/lib/instrument/ebin -pa _build/bench/lib/hackney/ebin -pa _build/bench/lib/idna/ebin -pa _build/bench/lib/mimerl/ebin -pa _build/bench/lib/ssl_verify_fun/ebin -pa _build/bench/lib/unicode_util_compat/ebin -pa _build/bench/lib/certifi/ebin -pa _build/bench/lib/metrics/ebin -pa _build/bench/lib/parse_trans/ebin

main(Args) ->
    %% Parse arguments
    Benches = case Args of
        [] -> all;
        ["all"] -> all;
        ["counter"] -> counter;
        ["gauge"] -> gauge;
        ["histogram"] -> histogram;
        ["meter"] -> meter;
        ["tracer"] -> tracer;
        ["logger"] -> logger;
        ["help"] -> help;
        _ -> help
    end,

    case Benches of
        help ->
            io:format(user, "Usage: ./bench/run_bench.escript [benchmark]~n", []),
            io:format(user, "~n", []),
            io:format(user, "Available benchmarks:~n", []),
            io:format(user, "  all        - Run all benchmarks (default)~n", []),
            io:format(user, "  counter    - Benchmark counter operations~n", []),
            io:format(user, "  gauge      - Benchmark gauge operations~n", []),
            io:format(user, "  histogram  - Benchmark histogram operations~n", []),
            io:format(user, "  meter      - Benchmark OTel Meter API~n", []),
            io:format(user, "  tracer     - Benchmark OTel Tracer API~n", []),
            io:format(user, "  logger     - Benchmark OTel Logger integration~n", []),
            io:format(user, "~n", []),
            io:format(user, "Example: ./bench/run_bench.escript tracer~n", []),
            halt(0);
        _ ->
            run_benchmarks(Benches)
    end.

run_benchmarks(Benches) ->
    %% Start application
    {ok, _} = application:ensure_all_started(instrument),

    %% Install logger integration
    instrument_logger:install(),

    io:format(user, "~n=== Instrument Benchmarks ===~n~n", []),

    try
        case Benches of
            all ->
                instrument_bench:run_counter(),
                io:format(user, "~n", []),
                instrument_bench:run_gauge(),
                io:format(user, "~n", []),
                instrument_bench:run_histogram(),
                io:format(user, "~n", []),
                instrument_bench:run_meter(),
                io:format(user, "~n", []),
                instrument_bench:run_tracer(),
                io:format(user, "~n", []),
                instrument_bench:run_logger();
            counter ->
                instrument_bench:run_counter();
            gauge ->
                instrument_bench:run_gauge();
            histogram ->
                instrument_bench:run_histogram();
            meter ->
                instrument_bench:run_meter();
            tracer ->
                instrument_bench:run_tracer();
            logger ->
                instrument_bench:run_logger()
        end,
        io:format(user, "~n=== Benchmarks Complete ===~n", [])
    catch
        C:E:S ->
            io:format(user, "~nError: ~p:~p~n~p~n", [C, E, S]),
            halt(1)
    after
        instrument_logger:uninstall()
    end,
    halt(0).
