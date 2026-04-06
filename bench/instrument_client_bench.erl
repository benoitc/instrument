%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Client tracing strategy benchmarks.
%%
%% Compares different approaches to client tracing:
%% - Manual tracing vs instrument_client helpers
%% - Different sanitization strategies
%% - Different sampling configurations
%% - Trace context injection overhead
%%
%% Run with: rebar3 as bench shell --eval 'instrument_client_bench:run().'
%%
%% Or run specific benchmarks:
%%   instrument_client_bench:run_client_span().
%%   instrument_client_bench:run_sanitization().
%%   instrument_client_bench:run_sampling().
%%   instrument_client_bench:run_trace_injection().
-module(instrument_client_bench).
-author("benoitc").

-export([
    run/0,
    run_client_span/0,
    run_sanitization/0,
    run_sampling/0,
    run_trace_injection/0,
    run_pool_span/0
]).

-define(DEFAULT_ITERATIONS, 50000).
-define(WARMUP_ITERATIONS, 1000).

%% ============================================================================
%% Public API
%% ============================================================================

%% @doc Runs all client tracing benchmarks.
-spec run() -> ok.
run() ->
    io:format(user, "~n=== Client Tracing Strategy Benchmarks ===~n~n", []),
    {ok, _} = application:ensure_all_started(instrument),
    try
        run_client_span(),
        io:format(user, "~n", []),
        run_sanitization(),
        io:format(user, "~n", []),
        run_sampling(),
        io:format(user, "~n", []),
        run_trace_injection(),
        io:format(user, "~n", []),
        run_pool_span(),
        io:format(user, "~n=== Client Tracing Benchmarks Complete ===~n", [])
    after
        %% Reset sampler
        instrument_sampler:set_sampler(instrument_sampler_always_on)
    end,
    ok.

%% @doc Compare manual tracing vs instrument_client helpers.
-spec run_client_span() -> ok.
run_client_span() ->
    io:format(user, "--- Client Span Strategy Comparison ---~n", []),
    io:format(user, "  Comparing: manual vs instrument_client helpers~n~n", []),

    %% Warmup
    warmup(fun() -> manual_client_span() end),

    %% 1. Manual tracing with instrument_tracer
    R1 = bench(?DEFAULT_ITERATIONS, fun() -> manual_client_span() end),
    format_result("manual (tracer:with_span)", R1),

    %% 2. instrument_client:with_client_span basic
    R2 = bench(?DEFAULT_ITERATIONS, fun() -> client_span_basic() end),
    format_result("instrument_client:with_span", R2),

    %% 3. instrument_client with all options
    R3 = bench(?DEFAULT_ITERATIONS, fun() -> client_span_full() end),
    format_result("client:with_span (full opts)", R3),

    %% 4. instrument_client with sanitization
    R4 = bench(?DEFAULT_ITERATIONS, fun() -> client_span_sanitized() end),
    format_result("client:with_span + sanitize", R4),

    %% 5. No tracing (baseline)
    R5 = bench(?DEFAULT_ITERATIONS, fun() -> no_tracing() end),
    format_result("no tracing (baseline)", R5),

    %% Calculate overheads
    {_, _, _, AvgBaseline} = R5,
    {_, _, _, AvgManual} = R1,
    {_, _, _, AvgClient} = R2,
    {_, _, _, AvgFull} = R3,
    {_, _, _, AvgSanitized} = R4,

    io:format(user, "~n  Overhead Analysis:~n", []),
    io:format(user, "    Manual tracing:     +~.2f us/op~n", [(AvgManual - AvgBaseline) / 1000]),
    io:format(user, "    instrument_client:  +~.2f us/op~n", [(AvgClient - AvgBaseline) / 1000]),
    io:format(user, "    Full options:       +~.2f us/op~n", [(AvgFull - AvgBaseline) / 1000]),
    io:format(user, "    With sanitization:  +~.2f us/op~n", [(AvgSanitized - AvgBaseline) / 1000]),

    ok.

manual_client_span() ->
    instrument_tracer:with_span(<<"postgresql SELECT users">>, #{kind => client}, fun() ->
        instrument_tracer:set_attributes(#{
            <<"db.system">> => <<"postgresql">>,
            <<"db.operation">> => <<"SELECT">>,
            <<"db.sql.table">> => <<"users">>,
            <<"db.statement">> => <<"SELECT * FROM users WHERE id = $1">>
        }),
        ok
    end).

client_span_basic() ->
    instrument_client:with_client_span(postgresql, <<"SELECT">>, fun() -> ok end).

client_span_full() ->
    instrument_client:with_client_span(postgresql, <<"SELECT">>, #{
        target => <<"users">>,
        statement => <<"SELECT * FROM users WHERE id = $1">>,
        attributes => #{<<"db.name">> => <<"mydb">>}
    }, fun() -> ok end).

client_span_sanitized() ->
    instrument_client:with_client_span(postgresql, <<"SELECT">>, #{
        target => <<"users">>,
        statement => <<"SELECT * FROM users WHERE id = 12345 AND name = 'John'">>,
        sanitize => true
    }, fun() -> ok end).

no_tracing() ->
    ok.

%% @doc Benchmark different sanitization strategies.
-spec run_sanitization() -> ok.
run_sanitization() ->
    io:format(user, "--- Sanitization Strategy Comparison ---~n", []),
    io:format(user, "  Comparing: none vs default vs custom patterns~n~n", []),

    SQL = <<"SELECT * FROM users WHERE id = 12345 AND email = 'john@example.com' AND status = 'active'">>,
    LongSQL = iolist_to_binary([
        <<"SELECT u.id, u.name, u.email, o.total FROM users u ">>,
        <<"JOIN orders o ON u.id = o.user_id ">>,
        <<"WHERE u.created_at > '2024-01-01' AND o.amount > 100.50 ">>,
        <<"AND u.status IN ('active', 'pending') ORDER BY o.created_at DESC LIMIT 100">>
    ]),

    %% Warmup
    warmup(fun() -> instrument_client:sanitize_text(SQL) end),

    %% 1. No sanitization
    R1 = bench(?DEFAULT_ITERATIONS, fun() -> SQL end),
    format_result("no sanitization", R1),

    %% 2. Default sanitization (short SQL)
    R2 = bench(?DEFAULT_ITERATIONS, fun() -> instrument_client:sanitize_text(SQL) end),
    format_result("default sanitize (short)", R2),

    %% 3. Default sanitization (long SQL)
    R3 = bench(?DEFAULT_ITERATIONS, fun() -> instrument_client:sanitize_text(LongSQL) end),
    format_result("default sanitize (long)", R3),

    %% 4. Custom placeholder
    R4 = bench(?DEFAULT_ITERATIONS, fun() ->
        instrument_client:sanitize_text(SQL, #{placeholder => <<"<?>">>})
    end),
    format_result("custom placeholder", R4),

    %% 5. Preserve patterns (PostgreSQL $N)
    SQLWithParams = <<"SELECT * FROM users WHERE id = $1 AND name = 'John' AND count > 100">>,
    R5 = bench(?DEFAULT_ITERATIONS, fun() ->
        instrument_client:sanitize_text(SQLWithParams, #{preserve => [<<"\\$\\d+">>]})
    end),
    format_result("preserve $N params", R5),

    %% 6. URL path sanitization
    URL = <<"/api/users/12345/orders/67890/items">>,
    R6 = bench(?DEFAULT_ITERATIONS, fun() ->
        instrument_client:sanitize_text(URL, #{
            patterns => [<<"/\\d+">>],
            placeholder => <<"/:id">>
        })
    end),
    format_result("URL path sanitize", R6),

    ok.

%% @doc Benchmark different sampling strategies.
-spec run_sampling() -> ok.
run_sampling() ->
    io:format(user, "--- Sampling Strategy Comparison ---~n", []),
    io:format(user, "  Comparing: always_on vs probability vs attribute-based~n~n", []),

    %% Warmup with always_on
    instrument_sampler:set_sampler(instrument_sampler_always_on),
    warmup(fun() -> sample_span() end),

    %% 1. Always On (100%)
    instrument_sampler:set_sampler(instrument_sampler_always_on),
    R1 = bench(?DEFAULT_ITERATIONS, fun() -> sample_span() end),
    format_result("always_on (100%)", R1),

    %% 2. Always Off (0%)
    instrument_sampler:set_sampler(instrument_sampler_always_off),
    R2 = bench(?DEFAULT_ITERATIONS, fun() -> sample_span() end),
    format_result("always_off (0%)", R2),

    %% 3. Probability 50%
    instrument_sampler:set_sampler(instrument_sampler_probability, #{ratio => 0.5}),
    R3 = bench(?DEFAULT_ITERATIONS, fun() -> sample_span() end),
    format_result("probability (50%)", R3),

    %% 4. Probability 10%
    instrument_sampler:set_sampler(instrument_sampler_probability, #{ratio => 0.1}),
    R4 = bench(?DEFAULT_ITERATIONS, fun() -> sample_span() end),
    format_result("probability (10%)", R4),

    %% 5. Probability 1%
    instrument_sampler:set_sampler(instrument_sampler_probability, #{ratio => 0.01}),
    R5 = bench(?DEFAULT_ITERATIONS, fun() -> sample_span() end),
    format_result("probability (1%)", R5),

    %% 6. Attribute-based (no rules match)
    instrument_sampler:set_sampler(instrument_sampler_attribute, #{
        default_ratio => 0.1,
        attribute_rules => []
    }),
    R6 = bench(?DEFAULT_ITERATIONS, fun() -> sample_span() end),
    format_result("attribute (no rules)", R6),

    %% 7. Attribute-based (with rules, match)
    instrument_sampler:set_sampler(instrument_sampler_attribute, #{
        default_ratio => 0.01,
        attribute_rules => [
            {<<"db.operation">>, <<"SELECT">>, 0.5}
        ]
    }),
    R7 = bench(?DEFAULT_ITERATIONS, fun() -> sample_span_with_attrs() end),
    format_result("attribute (1 rule match)", R7),

    %% 8. Attribute-based (with many rules)
    instrument_sampler:set_sampler(instrument_sampler_attribute, #{
        default_ratio => 0.01,
        attribute_rules => [
            {<<"error">>, true, 1.0},
            {<<"db.operation">>, <<"DELETE">>, 0.5},
            {<<"db.operation">>, <<"UPDATE">>, 0.1},
            {<<"db.operation">>, <<"INSERT">>, 0.05},
            {<<"db.operation">>, <<"SELECT">>, 0.01},
            {<<"db.sql.table">>, <<"audit_log">>, 1.0},
            {<<"http.status_code">>, 500, 1.0}
        ]
    }),
    R8 = bench(?DEFAULT_ITERATIONS, fun() -> sample_span_with_attrs() end),
    format_result("attribute (7 rules)", R8),

    %% Reset
    instrument_sampler:set_sampler(instrument_sampler_always_on),

    %% Calculate decision overhead
    {_, _, _, AvgAlwaysOn} = R1,
    {_, _, _, AvgAlwaysOff} = R2,
    {_, _, _, AvgProb} = R3,
    {_, _, _, AvgAttr} = R6,
    {_, _, _, AvgAttrRules} = R8,

    io:format(user, "~n  Decision Overhead (vs always_on):~n", []),
    io:format(user, "    always_off:        ~.2f us/op (dropped spans are cheap)~n",
              [(AvgAlwaysOff - AvgAlwaysOn) / 1000]),
    io:format(user, "    probability:       +~.2f us/op~n", [(AvgProb - AvgAlwaysOn) / 1000]),
    io:format(user, "    attribute (empty): +~.2f us/op~n", [(AvgAttr - AvgAlwaysOn) / 1000]),
    io:format(user, "    attribute (7 rules): +~.2f us/op~n", [(AvgAttrRules - AvgAlwaysOn) / 1000]),

    ok.

sample_span() ->
    instrument_tracer:with_span(<<"sample_test">>, fun() -> ok end).

sample_span_with_attrs() ->
    instrument_tracer:with_span(<<"sample_test">>, #{
        attributes => #{<<"db.operation">> => <<"SELECT">>}
    }, fun() -> ok end).

%% @doc Benchmark trace context injection strategies.
-spec run_trace_injection() -> ok.
run_trace_injection() ->
    io:format(user, "--- Trace Context Injection Comparison ---~n", []),
    io:format(user, "  Comparing: SQL comment vs URL params vs no injection~n~n", []),

    SQL = <<"SELECT * FROM users WHERE id = $1">>,
    URL = <<"/api/users/123">>,

    %% Must be inside a span for trace context
    instrument_tracer:with_span(<<"bench_injection">>, fun() ->
        %% Warmup
        warmup(fun() -> instrument_client:inject_trace_comment(SQL) end),

        %% 1. No injection
        R1 = bench(?DEFAULT_ITERATIONS, fun() -> SQL end),
        format_result("no injection", R1),

        %% 2. SQL comment format
        R2 = bench(?DEFAULT_ITERATIONS, fun() ->
            instrument_client:inject_trace_comment(SQL, #{format => sql})
        end),
        format_result("SQL comment format", R2),

        %% 3. URL query param format
        R3 = bench(?DEFAULT_ITERATIONS, fun() ->
            instrument_client:inject_trace_comment(URL, #{format => url})
        end),
        format_result("URL param format", R3),

        %% 4. Custom format
        R4 = bench(?DEFAULT_ITERATIONS, fun() ->
            instrument_client:inject_trace_comment(SQL, #{
                format => custom,
                prefix => <<"/* ">>,
                suffix => <<" */">>
            })
        end),
        format_result("custom format", R4),

        %% 5. Format comment only (no append)
        R5 = bench(?DEFAULT_ITERATIONS, fun() ->
            instrument_client:format_trace_comment()
        end),
        format_result("format_trace_comment/0", R5),

        ok
    end),
    ok.

%% @doc Benchmark pool span helpers.
-spec run_pool_span() -> ok.
run_pool_span() ->
    io:format(user, "--- Pool Span Helpers Comparison ---~n", []),
    io:format(user, "  Comparing: manual vs pool helpers~n~n", []),

    %% Warmup
    warmup(fun() -> manual_pool_tracking() end),

    %% 1. No pool tracking
    R1 = bench(?DEFAULT_ITERATIONS, fun() -> no_pool_tracking() end),
    format_result("no pool tracking", R1),

    %% 2. Manual pool tracking
    R2 = bench(?DEFAULT_ITERATIONS, fun() -> manual_pool_tracking() end),
    format_result("manual pool spans", R2),

    %% 3. pool_acquire_span + release
    R3 = bench(?DEFAULT_ITERATIONS, fun() -> helper_pool_tracking() end),
    format_result("pool_acquire/release", R3),

    %% 4. with_pool_span wrapper
    R4 = bench(?DEFAULT_ITERATIONS, fun() -> with_pool_span_tracking() end),
    format_result("with_pool_span", R4),

    ok.

no_pool_tracking() ->
    %% Simulate checkout/checkin without tracing
    _Conn = fake_checkout(),
    fake_checkin(_Conn),
    ok.

manual_pool_tracking() ->
    %% Manual implementation of pool tracing
    AcquireSpan = instrument_tracer:start_span(<<"pool.acquire">>, #{kind => client}),
    instrument_tracer:set_attributes(#{
        <<"pool.name">> => <<"db_pool">>,
        <<"pool.type">> => <<"postgresql">>
    }),
    _Conn = fake_checkout(),
    instrument_tracer:end_span(AcquireSpan),

    fake_checkin(_Conn),
    instrument_tracer:add_event(<<"pool.release">>, #{<<"pool.name">> => <<"db_pool">>}),
    ok.

helper_pool_tracking() ->
    Span = instrument_client:pool_acquire_span(<<"db_pool">>, postgresql),
    _Conn = fake_checkout(),
    instrument_tracer:end_span(Span),

    fake_checkin(_Conn),
    instrument_client:pool_release_span(<<"db_pool">>),
    ok.

with_pool_span_tracking() ->
    instrument_client:with_pool_span(<<"db_pool">>, postgresql, fun() ->
        _Conn = fake_checkout(),
        fake_checkin(_Conn),
        ok
    end).

fake_checkout() -> {conn, self()}.
fake_checkin(_Conn) -> ok.

%% ============================================================================
%% Internal Functions
%% ============================================================================

warmup(Fun) ->
    lists:foreach(fun(_) -> Fun() end, lists:seq(1, ?WARMUP_ITERATIONS)).

-spec bench(pos_integer(), fun(() -> any())) ->
    {non_neg_integer(), pos_integer(), float(), float()}.
bench(Iterations, Fun) ->
    erlang:garbage_collect(),
    Start = erlang:monotonic_time(nanosecond),
    run_iterations(Fun, Iterations),
    End = erlang:monotonic_time(nanosecond),
    TotalTimeNs = End - Start,
    TotalTimeSec = TotalTimeNs / 1_000_000_000,
    OpsPerSec = Iterations / TotalTimeSec,
    AvgTimeNs = TotalTimeNs / Iterations,
    {TotalTimeNs, Iterations, OpsPerSec, AvgTimeNs}.

run_iterations(_Fun, 0) -> ok;
run_iterations(Fun, N) ->
    Fun(),
    run_iterations(Fun, N - 1).

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
