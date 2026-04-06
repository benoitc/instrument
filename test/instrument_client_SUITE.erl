%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_client_SUITE).
-author("benoitc").

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("instrument_otel.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    %% Sanitization tests
    sanitize_sql_literals_test/1,
    sanitize_numbers_test/1,
    sanitize_url_segments_test/1,
    sanitize_preserve_patterns_test/1,
    sanitize_custom_placeholder_test/1,

    %% Trace comment tests
    trace_comment_sql_format_test/1,
    trace_comment_url_format_test/1,
    trace_comment_custom_format_test/1,
    trace_comment_no_context_test/1,

    %% Client span tests
    with_client_span_test/1,
    with_client_span_opts_test/1,
    start_client_span_test/1,
    client_span_name_test/1,

    %% Attribute tests
    build_attributes_db_test/1,
    build_attributes_http_test/1,
    build_attributes_messaging_test/1,
    set_client_attributes_test/1,
    set_response_attributes_test/1,

    %% Pool span tests
    pool_acquire_span_test/1,
    with_pool_span_test/1
]).

all() ->
    [
        %% Sanitization tests
        sanitize_sql_literals_test,
        sanitize_numbers_test,
        sanitize_url_segments_test,
        sanitize_preserve_patterns_test,
        sanitize_custom_placeholder_test,

        %% Trace comment tests
        trace_comment_sql_format_test,
        trace_comment_url_format_test,
        trace_comment_custom_format_test,
        trace_comment_no_context_test,

        %% Client span tests
        with_client_span_test,
        with_client_span_opts_test,
        start_client_span_test,
        client_span_name_test,

        %% Attribute tests
        build_attributes_db_test,
        build_attributes_http_test,
        build_attributes_messaging_test,
        set_client_attributes_test,
        set_response_attributes_test,

        %% Pool span tests
        pool_acquire_span_test,
        with_pool_span_test
    ].

init_per_suite(Config) ->
    _ = application:ensure_all_started(crypto),
    ok = application:start(instrument),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(instrument),
    ok.

init_per_testcase(_TestCase, Config) ->
    %% Reset to default sampler
    instrument_sampler:set_sampler(instrument_sampler_always_on),
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%% ============================================================================
%% Sanitization Tests
%% ============================================================================

sanitize_sql_literals_test(_Config) ->
    %% Single-quoted strings
    ?assertEqual(
        <<"SELECT * FROM users WHERE name = ?">>,
        instrument_client:sanitize_text(<<"SELECT * FROM users WHERE name = 'John'">>)
    ),

    %% Double-quoted strings (for identifiers in some DBs)
    ?assertEqual(
        <<"SELECT ? FROM users">>,
        instrument_client:sanitize_text(<<"SELECT \"column\" FROM users">>)
    ),

    %% Multiple values
    ?assertEqual(
        <<"INSERT INTO t (a, b) VALUES (?, ?)">>,
        instrument_client:sanitize_text(<<"INSERT INTO t (a, b) VALUES ('x', 'y')">>)
    ),

    ok.

sanitize_numbers_test(_Config) ->
    %% Integer
    ?assertEqual(
        <<"SELECT * FROM users WHERE id = ?">>,
        instrument_client:sanitize_text(<<"SELECT * FROM users WHERE id = 12345">>)
    ),

    %% Float
    ?assertEqual(
        <<"SELECT * FROM products WHERE price > ?">>,
        instrument_client:sanitize_text(<<"SELECT * FROM products WHERE price > 99.99">>)
    ),

    %% Hex
    ?assertEqual(
        <<"SELECT * FROM items WHERE hash = ?">>,
        instrument_client:sanitize_text(<<"SELECT * FROM items WHERE hash = 0xDEADBEEF">>)
    ),

    ok.

sanitize_url_segments_test(_Config) ->
    %% URL path sanitization with custom patterns
    Result = instrument_client:sanitize_text(<<"/users/12345/orders">>, #{
        patterns => [<<"/\\d+">>],
        placeholder => <<"/:id">>
    }),
    ?assertEqual(<<"/users/:id/orders">>, Result),

    ok.

sanitize_preserve_patterns_test(_Config) ->
    %% Preserve PostgreSQL placeholders ($1, $2, etc.)
    Result = instrument_client:sanitize_text(
        <<"SELECT * FROM users WHERE id = $1 AND name = 'John'">>,
        #{preserve => [<<"\\$\\d+">>]}
    ),
    ?assertEqual(<<"SELECT * FROM users WHERE id = $1 AND name = ?">>, Result),

    ok.

sanitize_custom_placeholder_test(_Config) ->
    Result = instrument_client:sanitize_text(
        <<"SELECT * FROM t WHERE x = 'foo'">>,
        #{placeholder => <<"<REDACTED>">>}
    ),
    ?assertEqual(<<"SELECT * FROM t WHERE x = <REDACTED>">>, Result),

    ok.

%% ============================================================================
%% Trace Comment Tests
%% ============================================================================

trace_comment_sql_format_test(_Config) ->
    instrument_tracer:with_span(<<"test">>, fun() ->
        Result = instrument_client:inject_trace_comment(<<"SELECT 1">>, #{format => sql}),
        %% Should have SQL comment format
        ?assertMatch(<<"SELECT 1 /*traceparent=", _/binary>>, Result),
        %% Should end with */
        ?assert(binary:match(Result, <<"*/">>) =/= nomatch)
    end),
    ok.

trace_comment_url_format_test(_Config) ->
    instrument_tracer:with_span(<<"test">>, fun() ->
        %% URL without query params
        Result1 = instrument_client:inject_trace_comment(<<"/api/data">>, #{format => url}),
        ?assertMatch(<<"/api/data?traceparent=", _/binary>>, Result1),

        %% URL with existing query params
        Result2 = instrument_client:inject_trace_comment(<<"/api/data?foo=bar">>, #{format => url}),
        ?assertMatch(<<"/api/data?foo=bar&traceparent=", _/binary>>, Result2)
    end),
    ok.

trace_comment_custom_format_test(_Config) ->
    instrument_tracer:with_span(<<"test">>, fun() ->
        Result = instrument_client:inject_trace_comment(<<"test">>, #{
            format => custom,
            prefix => <<"[">>,
            suffix => <<"]">>
        }),
        ?assertMatch(<<"test [traceparent=", _/binary>>, Result)
    end),
    ok.

trace_comment_no_context_test(_Config) ->
    %% Outside a span, should return text unchanged
    Result = instrument_client:inject_trace_comment(<<"SELECT 1">>),
    ?assertEqual(<<"SELECT 1">>, Result),
    ok.

%% ============================================================================
%% Client Span Tests
%% ============================================================================

with_client_span_test(_Config) ->
    Result = instrument_client:with_client_span(postgresql, <<"SELECT">>, fun() ->
        Span = instrument_tracer:current_span(),
        ?assertNotEqual(undefined, Span),
        ?assertEqual(client, Span#span.kind),
        {ok, done}
    end),
    ?assertEqual({ok, done}, Result),
    ok.

with_client_span_opts_test(_Config) ->
    Result = instrument_client:with_client_span(postgresql, <<"SELECT">>, #{
        target => <<"users">>,
        statement => <<"SELECT * FROM users WHERE id = 1">>,
        sanitize => true,
        attributes => #{<<"db.name">> => <<"testdb">>}
    }, fun() ->
        Span = instrument_tracer:current_span(),
        Attrs = Span#span.attributes,

        %% Check span name includes target
        ?assertEqual(<<"postgresql SELECT users">>, Span#span.name),

        %% Check attributes
        ?assertEqual(<<"postgresql">>, maps:get(<<"db.system">>, Attrs)),
        ?assertEqual(<<"SELECT">>, maps:get(<<"db.operation">>, Attrs)),
        ?assertEqual(<<"users">>, maps:get(<<"db.sql.table">>, Attrs)),
        ?assertEqual(<<"testdb">>, maps:get(<<"db.name">>, Attrs)),

        %% Check statement is sanitized
        Statement = maps:get(<<"db.statement">>, Attrs),
        ?assertEqual(<<"SELECT * FROM users WHERE id = ?">>, Statement),

        ok
    end),
    ?assertEqual(ok, Result),
    ok.

start_client_span_test(_Config) ->
    Span = instrument_client:start_client_span(redis, <<"GET">>),
    ?assertEqual(client, Span#span.kind),
    ?assertEqual(<<"redis GET">>, Span#span.name),
    instrument_tracer:end_span(Span),
    ok.

client_span_name_test(_Config) ->
    %% Without target
    ?assertEqual(<<"postgresql SELECT">>,
        instrument_client:client_span_name(postgresql, <<"SELECT">>)),

    %% With target
    ?assertEqual(<<"postgresql SELECT users">>,
        instrument_client:client_span_name(postgresql, <<"SELECT">>, #{target => <<"users">>})),

    %% Binary system
    ?assertEqual(<<"kafka publish">>,
        instrument_client:client_span_name(<<"kafka">>, <<"publish">>)),

    ok.

%% ============================================================================
%% Attribute Tests
%% ============================================================================

build_attributes_db_test(_Config) ->
    Attrs = instrument_client:build_attributes(#{
        system => postgresql,
        operation => <<"SELECT">>,
        target => <<"users">>,
        statement => <<"SELECT * FROM users">>,
        attributes => #{<<"db.name">> => <<"mydb">>}
    }),

    ?assertEqual(<<"postgresql">>, maps:get(<<"db.system">>, Attrs)),
    ?assertEqual(<<"SELECT">>, maps:get(<<"db.operation">>, Attrs)),
    ?assertEqual(<<"users">>, maps:get(<<"db.sql.table">>, Attrs)),
    ?assertEqual(<<"SELECT * FROM users">>, maps:get(<<"db.statement">>, Attrs)),
    ?assertEqual(<<"mydb">>, maps:get(<<"db.name">>, Attrs)),
    ok.

build_attributes_http_test(_Config) ->
    Attrs = instrument_client:build_attributes(#{
        system => http,
        operation => <<"GET">>,
        target => <<"/api/users">>,
        attributes => #{<<"http.url">> => <<"https://api.example.com/users">>}
    }),

    ?assertEqual(<<"GET">>, maps:get(<<"http.method">>, Attrs)),
    ?assertEqual(<<"/api/users">>, maps:get(<<"http.target">>, Attrs)),
    ?assertEqual(<<"https://api.example.com/users">>, maps:get(<<"http.url">>, Attrs)),
    ok.

build_attributes_messaging_test(_Config) ->
    Attrs = instrument_client:build_attributes(#{
        system => kafka,
        operation => <<"publish">>,
        target => <<"orders-topic">>,
        attributes => #{<<"messaging.destination.kind">> => <<"topic">>}
    }),

    ?assertEqual(<<"kafka">>, maps:get(<<"messaging.system">>, Attrs)),
    ?assertEqual(<<"publish">>, maps:get(<<"messaging.operation">>, Attrs)),
    ?assertEqual(<<"orders-topic">>, maps:get(<<"messaging.destination">>, Attrs)),
    ?assertEqual(<<"topic">>, maps:get(<<"messaging.destination.kind">>, Attrs)),
    ok.

set_client_attributes_test(_Config) ->
    instrument_tracer:with_span(<<"test">>, fun() ->
        instrument_client:set_client_attributes(#{
            system => postgresql,
            operation => <<"INSERT">>,
            target => <<"orders">>
        }),
        Span = instrument_tracer:current_span(),
        Attrs = Span#span.attributes,
        ?assertEqual(<<"postgresql">>, maps:get(<<"db.system">>, Attrs)),
        ?assertEqual(<<"INSERT">>, maps:get(<<"db.operation">>, Attrs)),
        ok
    end),
    ok.

set_response_attributes_test(_Config) ->
    instrument_tracer:with_span(<<"test">>, fun() ->
        instrument_client:set_response_attributes(#{
            rows_returned => 42,
            rows_affected => 5,
            status_code => 200
        }),
        Span = instrument_tracer:current_span(),
        Attrs = Span#span.attributes,
        ?assertEqual(42, maps:get(<<"db.rows_returned">>, Attrs)),
        ?assertEqual(5, maps:get(<<"db.rows_affected">>, Attrs)),
        ?assertEqual(200, maps:get(<<"http.status_code">>, Attrs)),
        ok
    end),
    ok.

%% ============================================================================
%% Pool Span Tests
%% ============================================================================

pool_acquire_span_test(_Config) ->
    Span = instrument_client:pool_acquire_span(<<"db_pool">>, postgresql),
    ?assertEqual(client, Span#span.kind),
    ?assertMatch(<<"postgresql pool.acquire">>, Span#span.name),

    Attrs = Span#span.attributes,
    ?assertEqual(<<"db_pool">>, maps:get(<<"pool.name">>, Attrs)),
    ?assertEqual(<<"postgresql">>, maps:get(<<"pool.type">>, Attrs)),

    instrument_tracer:end_span(Span),
    ok.

with_pool_span_test(_Config) ->
    Result = instrument_client:with_pool_span(<<"db_pool">>, postgresql, fun() ->
        %% Simulate using the pool resource
        {ok, resource_used}
    end),
    ?assertEqual({ok, resource_used}, Result),
    ok.
