%% Copyright (c) 2026, Grigory Starinkin <starinkin@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Master-vs-branch performance benchmark for the series store
%% (Task 11 of the series-store plan). Verifies the §10 performance
%% contract of docs/superpowers/specs/2026-06-11-series-store-design.md
%% empirically.
%%
%% Self-contained and build-agnostic: scenarios 1-5 and 7 call only public
%% API that exists byte-identically on both `be7e75e` (master) and the
%% series-store branch, so the SAME compiled module runs against EITHER
%% build purely via code path. Scenario-setup differences are guarded by
%% catching `undef` / probing `erlang:function_exported/3`; no scenario
%% calls a branch-only function.
%%
%% Method (mirrors bench/instrument_bench.erl's monotonic_time style):
%%   * hot loops (scenarios 1-5,7): N=1_000_000 iterations, 3 warmup runs
%%     then 5 measured runs, report MEDIAN ns/op.
%%   * storm (scenario 6): wall-clock of P procs x M distinct first-touches
%%     completing (spawn + barrier + await all), 3 runs, median; the registry
%%     message_queue_len sampled every 10ms during the storm (report max);
%%     literal-GC sweeps inferred from erlang:statistics(garbage_collection)
%%     total-count delta (a replacing persistent_term:put of a non-immediate
%%     term forces a global GC pass in every live process, so the global GC
%%     count jumps by ~live-process-count per sweep; a fresh put does not).
%%
%% Run (after `rebar3 as bench compile` or with the build on the code path):
%%   instrument_series_bench:run().
%%   instrument_series_bench:run_json("/tmp/out.json").   %% machine-readable
-module(instrument_series_bench).

-export([
    run/0,
    run_hot/0,
    run_storm/0,
    run_json/1,
    run_hot_json/1,
    run_storm_json/1,
    %% individual scenarios (for ad-hoc use)
    scenario_1_simple_inc/0,
    scenario_2_meter_add_unlabeled/0,
    scenario_3_meter_add_labeled/0,
    scenario_4_meter_record_labeled/0,
    scenario_5_vec_inc/0,
    scenario_6_storm/0,
    scenario_7_collect/0
]).

-define(N, 1000000).
-define(WARMUP_RUNS, 3).
-define(MEASURED_RUNS, 5).

%% Storm parameters (spec scenario 6): P procs, each M DISTINCT new label
%% sets, all under ONE shared instrument.
-define(STORM_P, 32).
-define(STORM_M, 500).
%% Master serialises + sweeps per series (~3.4 GC passes/series, ~190
%% series/sec single-proc -> the full 16k-series storm runs for ~80-120s and
%% may not complete inside the deadline), so the heavy storm is run ONCE per
%% suite: the master-vs-branch contrast (wall-clock, queue depth, sweeps) is
%% stable and binary, not noise-limited. Hot-path scenarios still take 5
%% measured runs (see ?MEASURED_RUNS).
-define(STORM_RUNS, 1).
-define(STORM_QUEUE_SAMPLE_MS, 10).
%% Idle processes parked during the storm so a literal-GC sweep has a
%% population to scan: a sweep forces a GC in every one of them, so the
%% global GC count jumps by ~STORM_IDLERS per sweep. Master replaces a pt
%% term per new series (a sweep each); the branch puts only fresh keys
%% (no sweep). Normalising the GC delta by series_created gives sweeps/series
%% ~= STORM_IDLERS on master, ~= 0 on the branch.
-define(STORM_IDLERS, 100).
%% Per-storm-run deadline. Master serialises + sweeps per series and can run
%% for minutes at 16k series; the branch finishes in well under a second. We
%% record how far the storm got at this deadline rather than hanging.
-define(STORM_DEADLINE_MS, 90000).

%% Collection corpus size (spec scenario 7).
-define(COLLECT_SERIES, 2000).

%% ============================================================================
%% Public API
%% ============================================================================

%% @doc Run every scenario (hot paths + the heavy storm). Returns the raw
%% results proplist so a caller (e.g. an escript) can serialize it.
-spec run() -> [{atom(), term()}].
run() ->
    Build = start_and_banner(),
    Results = [{build, Build} | hot_scenarios() ++ [{scenario_6, scenario_6_storm()}]],
    io:format(user, "~n=== Complete ===~n", []),
    Results.

%% @doc Run only the hot-path + collect scenarios (1-5, 7). These are the
%% rows averaged across interleaved master/branch pairs; the heavy storm (6)
%% is run separately (run_storm/0) so its long master wall-clock does not
%% multiply across pairs.
-spec run_hot() -> [{atom(), term()}].
run_hot() ->
    Build = start_and_banner(),
    Results = [{build, Build} | hot_scenarios()],
    io:format(user, "~n=== Hot scenarios complete ===~n", []),
    Results.

%% @doc Run only the first-touch storm (scenario 6).
-spec run_storm() -> [{atom(), term()}].
run_storm() ->
    Build = start_and_banner(),
    Results = [{build, Build}, {scenario_6, scenario_6_storm()}],
    io:format(user, "~n=== Storm complete ===~n", []),
    Results.

start_and_banner() ->
    {ok, _} = application:ensure_all_started(instrument),
    Build = which_build(),
    io:format(user, "~n=== Series-Store Benchmark (build: ~s) ===~n~n", [Build]),
    Build.

hot_scenarios() ->
    [ {scenario_1, scenario_1_simple_inc()}
    , {scenario_2, scenario_2_meter_add_unlabeled()}
    , {scenario_3, scenario_3_meter_add_labeled()}
    , {scenario_4, scenario_4_meter_record_labeled()}
    , {scenario_5, scenario_5_vec_inc()}
    , {scenario_7, scenario_7_collect()}
    ].

%% @doc Run everything and write the results as a flat JSON object to File.
%% No external deps — emits JSON by hand (only numbers/strings/atoms).
-spec run_json(file:filename()) -> ok.
run_json(File) -> write_json(File, run()).

%% @doc Hot-path + collect scenarios only, to JSON.
-spec run_hot_json(file:filename()) -> ok.
run_hot_json(File) -> write_json(File, run_hot()).

%% @doc Storm scenario only, to JSON.
-spec run_storm_json(file:filename()) -> ok.
run_storm_json(File) -> write_json(File, run_storm()).

write_json(File, Results) ->
    ok = file:write_file(File, to_json(Results)),
    io:format(user, "~nwrote ~s~n", [File]),
    ok.

%% ============================================================================
%% Scenario 1: record-held simple inc_counter/1 (direct NIF; identical on both)
%% ============================================================================
scenario_1_simple_inc() ->
    Counter = instrument_metric:new_counter(sbench_simple_counter,
                                            <<"series bench simple counter">>),
    Median = measure_hot(fun() -> instrument_metric:inc_counter(Counter) end),
    cleanup(fun() -> instrument_metric:unregister(sbench_simple_counter) end),
    report("1. simple inc_counter/1 (record-held, direct NIF)", Median).

%% ============================================================================
%% Scenario 2: meter add/2 unlabeled hot (THE accepted regression on branch)
%% ============================================================================
scenario_2_meter_add_unlabeled() ->
    Meter = instrument_meter:get_meter(<<"sbench">>),
    C = instrument_meter:create_counter(Meter, <<"sbench_add2">>,
                                        #{description => <<"unlabeled add">>}),
    Median = measure_hot(fun() -> instrument_meter:add(C, 1) end),
    cleanup(fun() -> instrument_meter:unregister_instrument(<<"sbench_add2">>) end),
    report("2. meter add/2 (unlabeled hot)", Median).

%% ============================================================================
%% Scenario 3: meter add/3 with 2 attrs, labeled hot (branch must be FASTER)
%% ============================================================================
scenario_3_meter_add_labeled() ->
    Meter = instrument_meter:get_meter(<<"sbench">>),
    C = instrument_meter:create_counter(Meter, <<"sbench_add3">>,
                                        #{description => <<"labeled add">>}),
    Attrs = #{method => <<"GET">>, status => 200},
    %% Touch once so the hot loop measures the steady-state cache-hit path,
    %% not the one-time first-write.
    _ = instrument_meter:add(C, 1, Attrs),
    Median = measure_hot(fun() -> instrument_meter:add(C, 1, Attrs) end),
    cleanup(fun() -> instrument_meter:unregister_instrument(<<"sbench_add3">>) end),
    report("3. meter add/3, 2 attrs (labeled hot)", Median).

%% ============================================================================
%% Scenario 4: meter record/3 with 2 attrs, histogram labeled hot
%% ============================================================================
scenario_4_meter_record_labeled() ->
    Meter = instrument_meter:get_meter(<<"sbench">>),
    H = instrument_meter:create_histogram(Meter, <<"sbench_rec3">>,
                                          #{description => <<"labeled record">>}),
    Attrs = #{method => <<"GET">>, status => 200},
    _ = instrument_meter:record(H, 0.125, Attrs),
    Median = measure_hot(fun() -> instrument_meter:record(H, 0.125, Attrs) end),
    cleanup(fun() -> instrument_meter:unregister_instrument(<<"sbench_rec3">>) end),
    report("4. meter record/3, 2 attrs (histogram labeled hot)", Median).

%% ============================================================================
%% Scenario 5: vec inc_counter_vec/3 hot (parity expected)
%% ============================================================================
scenario_5_vec_inc() ->
    ok = new_counter_vec(sbench_vec, <<"series bench vec">>, [method, status]),
    Vals = [<<"GET">>, <<"200">>],
    _ = instrument_metric:inc_counter_vec(sbench_vec, Vals, 1),
    Median = measure_hot(fun() ->
        instrument_metric:inc_counter_vec(sbench_vec, Vals, 1)
    end),
    cleanup(fun() -> instrument_metric:unregister(sbench_vec) end),
    report("5. vec inc_counter_vec/3 (hot)", Median).

%% ============================================================================
%% Scenario 6: first-touch storm. P procs x M DISTINCT new label sets each
%% (per-proc distinct), all under ONE shared meter counter instrument.
%% On master this drives ensure_vec_metric -> create_vector_metric (gen_server
%% call) + a replacing persistent_term:put per series (a sweep). On the branch
%% this drives the lock-free claim_row (2 fresh puts, no gen_server, no sweep).
%% Identical caller code on both.
%% ============================================================================
scenario_6_storm() ->
    %% Lift the cap well above P*M so the storm creates real series, not
    %% overflow (overflow would hide the very cost we are measuring).
    raise_cardinality_limit(),
    Runs = [storm_once(R) || R <- lists:seq(1, ?STORM_RUNS)],
    WallNs = median([W || #{wall_ns := W} <- Runs]),
    MaxQ = lists:max([Q || #{max_queue := Q} <- Runs]),
    SweepProxy = median([S || #{sweep_gc_delta := S} <- Runs]),
    Created = median([C || #{created := C} <- Runs]),
    AnyTimeout = lists:any(fun(#{status := S}) -> S =:= timeout end, Runs),
    %% Normalise: sweeps/series ~= idler-count on master (one all-process
    %% literal-GC pass per new series), ~= 0 on the branch (fresh puts only).
    PerSeries = case Created of
        0 -> 0.0;
        _ -> median([S / max(C, 1)
                     || #{sweep_gc_delta := S, created := C} <- Runs])
    end,
    StatusStr = case AnyTimeout of true -> "TIMED-OUT"; false -> "completed" end,
    io:format(user,
        "  ~-52s ~s wall(median)=~s  max_registry_q=~p  gc_sweep_delta(median)=~p  sweeps/series=~.2f  idlers=~p  series(median)=~p~n",
        [io_lib:format("6. first-touch storm P=~p x M=~p", [?STORM_P, ?STORM_M]),
         StatusStr, fmt_ns(WallNs), MaxQ, SweepProxy, PerSeries * 1.0,
         ?STORM_IDLERS, Created]),
    #{wall_ns => WallNs, max_queue => MaxQ, sweep_gc_delta => SweepProxy,
      sweeps_per_series => PerSeries, idlers => ?STORM_IDLERS,
      any_timeout => AnyTimeout, deadline_ms => ?STORM_DEADLINE_MS,
      created => Created, runs => Runs, p => ?STORM_P, m => ?STORM_M}.

storm_once(RunIx) ->
    Name = list_to_binary("sbench_storm_" ++ integer_to_list(RunIx)),
    Meter = instrument_meter:get_meter(<<"sbench_storm">>),
    _C0 = instrument_meter:create_counter(Meter, Name,
                                          #{description => <<"storm">>}),
    C = instrument_meter:get_instrument(Name),
    Parent = self(),
    %% Park a known number of idle processes so a literal-GC sweep has a
    %% population to scan -- this is what makes the global GC-count delta a
    %% legible sweep proxy. They are pure receivers; they never run user code.
    Idlers = [spawn(fun() -> receive stop -> ok end end)
              || _ <- lists:seq(1, ?STORM_IDLERS)],
    %% Build each worker's M DISTINCT label sets up front so the measured
    %% window contains only the writes, not the term construction.
    WorkSets = [distinct_attrs(P, ?STORM_M) || P <- lists:seq(1, ?STORM_P)],

    %% Settle, then snapshot the sweep proxy + start the queue sampler.
    quiesce(),
    Reg = whereis(instrument_registry),
    GC0 = total_gc_count(),
    Sampler = spawn_link(fun() -> sample_queue(Reg, Parent, 0) end),

    %% Barrier: spawn all workers, each waits for `go`, then hammers its sets.
    %% Master serialises every first-touch through the registry gen_server and
    %% schedules an all-process literal-GC sweep per series, so the full storm
    %% can blow past any sane timeout; the branch is lock-free and finishes in
    %% well under a second. We therefore time to a deadline and record HOW FAR
    %% the storm got rather than crashing -- a master timeout is itself the
    %% serialization-collapse evidence the contract predicts.
    Workers = [spawn_link(fun() ->
                    receive go -> ok end,
                    lists:foreach(
                      fun(Attrs) -> instrument_meter:add(C, 1, Attrs) end,
                      Sets),
                    Parent ! {worker_done, self()}
                end) || Sets <- WorkSets],
    Start = erlang:monotonic_time(nanosecond),
    [W ! go || W <- Workers],
    {Status, Done} = await_all(Workers, ?STORM_DEADLINE_MS, Start),
    End = erlang:monotonic_time(nanosecond),

    Sampler ! {stop, self()},
    MaxQ = receive {max_queue, Q} -> Q after 1000 -> -1 end,
    GC1 = total_gc_count(),
    %% Series live under the registry RegName {otel, Name} on both builds.
    Created = label_count_safe({otel, Name}),

    [P ! stop || P <- Idlers],
    cleanup(fun() -> instrument_meter:unregister_instrument(Name) end),
    #{wall_ns => End - Start,
      status => Status,
      workers_done => Done,
      max_queue => MaxQ,
      sweep_gc_delta => GC1 - GC0,
      created => Created,
      idlers => length(Idlers)}.

%% M distinct attribute maps for worker P; (P,I) makes every set globally
%% distinct so all P*M first-touches mint a fresh series.
distinct_attrs(P, M) ->
    [#{worker => integer_to_binary(P), seq => integer_to_binary(I)}
     || I <- lists:seq(1, M)].

%% Await workers up to an absolute deadline; never crashes. Returns
%% {completed, N} when all N finished, or {timeout, N} with N = finished-so-far.
await_all(Workers, DeadlineMs, StartNs) ->
    await_all(Workers, length(Workers), DeadlineMs, StartNs).

await_all([], Total, _DeadlineMs, _StartNs) ->
    {completed, Total};
await_all(Workers, Total, DeadlineMs, StartNs) ->
    ElapsedMs = (erlang:monotonic_time(nanosecond) - StartNs) div 1000000,
    Remaining = DeadlineMs - ElapsedMs,
    case Remaining =< 0 of
        true ->
            {timeout, Total - length(Workers)};
        false ->
            receive
                {worker_done, W} ->
                    await_all(lists:delete(W, Workers), Total, DeadlineMs, StartNs)
            after max(Remaining, 1) ->
                {timeout, Total - length(Workers)}
            end
    end.

%% Poll the registry mailbox depth every STORM_QUEUE_SAMPLE_MS, tracking max.
sample_queue(Reg, Parent, Max) ->
    receive
        {stop, Parent} -> Parent ! {max_queue, Max}
    after ?STORM_QUEUE_SAMPLE_MS ->
        Q = case Reg of
                undefined -> 0;
                _ ->
                    case erlang:process_info(Reg, message_queue_len) of
                        {message_queue_len, L} -> L;
                        undefined -> 0
                    end
            end,
        sample_queue(Reg, Parent, max(Max, Q))
    end.

%% ============================================================================
%% Scenario 7: collect/format at ~2000 series (chain/index walk; parity-ish)
%% ============================================================================
scenario_7_collect() ->
    raise_cardinality_limit(),
    Name = <<"sbench_collect">>,
    Meter = instrument_meter:get_meter(<<"sbench_collect">>),
    _ = instrument_meter:create_counter(Meter, Name, #{description => <<"collect">>}),
    C = instrument_meter:get_instrument(Name),
    %% Populate ~2000 distinct series under one family.
    Attrs = distinct_attrs(1, ?COLLECT_SERIES),
    lists:foreach(fun(A) -> instrument_meter:add(C, 1, A) end, Attrs),
    %% Measure the Prometheus text format/0 (full collect + render); this is
    %% the realistic scrape cost and exists on both builds.
    F = fun() -> _ = instrument_prometheus:format(), ok end,
    %% Collect is far heavier than a NIF op, so use fewer iterations.
    Median = measure_n(F, 200, ?WARMUP_RUNS, ?MEASURED_RUNS),
    OutBytes = iolist_size(instrument_prometheus:format()),
    cleanup(fun() -> instrument_meter:unregister_instrument(Name) end),
    io:format(user, "  ~-52s ~s/op  (output ~p bytes, ~p series)~n",
              ["7. collect+format at ~2000 series", fmt_ns(Median),
               OutBytes, ?COLLECT_SERIES]),
    #{ns_per_op => Median, output_bytes => OutBytes, series => ?COLLECT_SERIES}.

%% ============================================================================
%% Measurement core
%% ============================================================================

%% Hot-loop measurement at N iterations: WARMUP_RUNS warmups (discarded) then
%% MEASURED_RUNS measured runs; returns the MEDIAN ns/op across measured runs.
measure_hot(Fun) ->
    measure_n(Fun, ?N, ?WARMUP_RUNS, ?MEASURED_RUNS).

measure_n(Fun, N, Warmups, Measured) ->
    _ = [time_loop(Fun, N) || _ <- lists:seq(1, Warmups)],
    Samples = [time_loop(Fun, N) || _ <- lists:seq(1, Measured)],
    median(Samples).

%% One timed run of N iterations; returns ns/op for that run.
time_loop(Fun, N) ->
    erlang:garbage_collect(),
    Start = erlang:monotonic_time(nanosecond),
    loop(Fun, N),
    End = erlang:monotonic_time(nanosecond),
    (End - Start) / N.

loop(_Fun, 0) -> ok;
loop(Fun, N) -> Fun(), loop(Fun, N - 1).

%% ============================================================================
%% Helpers
%% ============================================================================

report(Label, NsPerOp) ->
    io:format(user, "  ~-52s ~s/op~n", [Label, fmt_ns(NsPerOp)]),
    #{ns_per_op => NsPerOp}.

fmt_ns(Ns) when is_number(Ns) ->
    lists:flatten(io_lib:format("~.1f ns", [Ns * 1.0])).

median([]) -> 0;
median(L) ->
    Sorted = lists:sort(L),
    Len = length(Sorted),
    Mid = Len div 2,
    case Len rem 2 of
        1 -> lists:nth(Mid + 1, Sorted);
        0 -> (lists:nth(Mid, Sorted) + lists:nth(Mid + 1, Sorted)) / 2
    end.

%% Total GC count across the whole VM (first element of the 3-tuple). A
%% literal-area collection (scheduled by replacing/erasing a non-immediate
%% persistent_term) forces a GC in EVERY live process, so this counter jumps
%% by ~(live process count) per sweep; a fresh put does not move it.
total_gc_count() ->
    {NumGCs, _WordsReclaimed, _} = erlang:statistics(garbage_collection),
    NumGCs.

%% Let scheduled work and any pending literal-GC drain before a measured
%% window so the snapshot is clean.
quiesce() ->
    erlang:garbage_collect(),
    timer:sleep(50).

%% New-counter-vec exists on both builds but lives in instrument_metric on
%% both; guard anyway so a future rename cannot silently skip the scenario.
new_counter_vec(Name, Help, Labels) ->
    case erlang:function_exported(instrument_metric, new_counter_vec, 3) of
        true -> instrument_metric:new_counter_vec(Name, Help, Labels);
        false -> error({missing, {instrument_metric, new_counter_vec, 3}})
    end.

%% label_count/1 is exported by instrument_registry on both builds; tolerate
%% its absence rather than crash the storm result.
label_count_safe(Name) ->
    try instrument_registry:label_count(Name)
    catch _:_ -> -1
    end.

%% Raise the per-metric cardinality cap so storm/collect create real series.
%% The cap reads OTEL_METRIC_CARDINALITY_LIMIT at call time on both builds.
raise_cardinality_limit() ->
    os:putenv("OTEL_METRIC_CARDINALITY_LIMIT", "100000"),
    ok.

cleanup(Fun) ->
    try Fun() catch _:_ -> ok end,
    ok.

%% Identify which build we are running against without calling a branch-only
%% function: instrument_series is a branch-only module.
which_build() ->
    case code:is_loaded(instrument_series) of
        false ->
            case code:where_is_file("instrument_series.beam") of
                non_existing -> "master (be7e75e)";
                _ -> "branch (series-store)"
            end;
        _ ->
            "branch (series-store)"
    end.

%% ----------------------------------------------------------------------------
%% Tiny hand JSON encoder (flat: numbers, strings, atoms, nested maps/lists
%% of those). Avoids any dependency so the same module runs on both builds.
%% ----------------------------------------------------------------------------
to_json(Term) ->
    iolist_to_binary(json_val(Term)).

json_val(M) when is_map(M) ->
    json_obj(maps:to_list(M));
json_val(L) when is_list(L) ->
    case is_proplist(L) of
        true -> json_obj(L);
        false -> json_arr(L)
    end;
json_val(A) when is_atom(A) -> [$", atom_to_list(A), $"];
json_val(B) when is_binary(B) -> [$", B, $"];
json_val(I) when is_integer(I) -> integer_to_list(I);
json_val(F) when is_float(F) -> io_lib:format("~.4f", [F]);
json_val(Other) -> [$", io_lib:format("~p", [Other]), $"].

is_proplist([]) -> false;
is_proplist(L) -> lists:all(fun({K, _}) when is_atom(K) -> true; (_) -> false end, L).

json_obj(KVs) ->
    Pairs = [[$", atom_to_list(K), "\":", json_val(V)] || {K, V} <- KVs],
    [${, lists:join($,, Pairs), $}].

json_arr(Items) ->
    [$[, lists:join($,, [json_val(I) || I <- Items]), $]].
