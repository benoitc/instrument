#!/usr/bin/env escript
%% -*- erlang -*-

%% Runner for instrument_series_bench. Build-agnostic: point it at a build's
%% _build/<profile>/lib directory and it loads instrument + deps from there,
%% so the SAME benchmark module (compiled once in the branch's bench profile)
%% runs against EITHER build purely via code path.
%%
%% Usage:
%%   bench/run_series_bench.escript <MODE> <LIB_DIR> <BENCH_EBIN> <OUT_JSON>
%%
%%   MODE       - all | hot | storm
%%   LIB_DIR    - a build's _build/<profile>/lib directory (instrument + deps)
%%   BENCH_EBIN - ebin holding instrument_series_bench.beam (the branch's
%%                bench-profile ebin; reused unchanged across builds)
%%   OUT_JSON   - path to write the flat JSON result object
main([Mode, LibDir, BenchEbin, OutJson]) ->
    add_libs(LibDir),
    %% The bench module is loaded LAST and from a fixed ebin so the exact same
    %% compiled code drives both builds. Everything it calls is public API
    %% resolved against whichever instrument is on the path (LibDir).
    true = code:add_patha(BenchEbin),
    case code:ensure_loaded(instrument_series_bench) of
        {module, _} -> ok;
        Err -> io:format(user, "cannot load bench module: ~p~n", [Err]), halt(2)
    end,
    Run = case Mode of
        "all"   -> fun instrument_series_bench:run_json/1;
        "hot"   -> fun instrument_series_bench:run_hot_json/1;
        "storm" -> fun instrument_series_bench:run_storm_json/1;
        _       -> io:format(user, "bad mode ~p~n", [Mode]), halt(2)
    end,
    try
        Run(OutJson),
        %% give async io/GC a moment, then exit cleanly
        timer:sleep(300),
        halt(0)
    catch
        C:E:S ->
            io:format(user, "~nBENCH ERROR ~p:~p~n~p~n", [C, E, S]),
            halt(1)
    end;
main(_) ->
    io:format(user,
              "usage: run_series_bench.escript <MODE> <LIB_DIR> <BENCH_EBIN> <OUT_JSON>~n",
              []),
    halt(2).

%% Add every <LibDir>/<app>/ebin to the code path.
add_libs(LibDir) ->
    case file:list_dir(LibDir) of
        {ok, Apps} ->
            [code:add_patha(filename:join([LibDir, App, "ebin"]))
             || App <- Apps],
            ok;
        {error, R} ->
            io:format(user, "cannot list ~s: ~p~n", [LibDir, R]),
            halt(2)
    end.
