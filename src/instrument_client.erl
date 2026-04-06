%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Generic client span utilities for tracing client operations.
%%
%% This module provides reusable utilities for creating client-kind spans
%% for any type of client operation: databases, HTTP clients, message queues,
%% RPC calls, etc.
%%
%% == Features ==
%% - Generic client span helpers with semantic convention support
%% - Text sanitization (SQL, URLs, messages)
%% - Trace context comment injection (SQLCommenter-style)
%% - Resource pool monitoring helpers
%% - Attribute builders following OTel conventions
%%
%% == Example Usage ==
%% ```
%% %% Database query
%% instrument_client:with_client_span(postgresql, <<"SELECT">>, #{
%%     target => <<"users">>,
%%     statement => <<"SELECT * FROM users WHERE id = $1">>,
%%     sanitize => true,
%%     attributes => #{<<"db.name">> => <<"mydb">>}
%% }, fun() ->
%%     epgsql:equery(Conn, SQL, Params)
%% end).
%%
%% %% HTTP client call
%% instrument_client:with_client_span(http, <<"GET">>, #{
%%     target => <<"/api/users">>,
%%     attributes => #{<<"http.url">> => URL}
%% }, fun() ->
%%     httpc:request(URL)
%% end).
%%
%% %% Message queue publish
%% instrument_client:with_client_span(kafka, <<"publish">>, #{
%%     target => <<"orders-topic">>,
%%     attributes => #{<<"messaging.destination">> => <<"orders-topic">>}
%% }, fun() ->
%%     brod:produce(Client, Topic, Key, Value)
%% end).
%% '''
-module(instrument_client).
-author("benoitc").

-include("instrument_otel.hrl").

%% Generic client span helpers
-export([with_client_span/3, with_client_span/4]).
-export([start_client_span/2, start_client_span/3]).

%% Text sanitization (generic - works for SQL, queries, URLs, etc.)
-export([sanitize_text/1, sanitize_text/2]).

%% Trace context comment injection (SQLCommenter-style, but generic)
-export([inject_trace_comment/1, inject_trace_comment/2]).
-export([format_trace_comment/0, format_trace_comment/1]).

%% Span naming helpers
-export([client_span_name/2, client_span_name/3]).

%% Resource pool helpers (generic for any pooled resource)
-export([with_pool_span/3, pool_acquire_span/2, pool_release_span/1]).

%% Attribute builders
-export([build_attributes/1, set_client_attributes/1]).
-export([set_response_attributes/1]).

-type client_system() :: atom() | binary().
-type operation() :: atom() | binary().

-type client_opts() :: #{
    system => client_system(),
    operation => binary(),
    target => binary(),
    statement => binary(),
    sanitize => boolean(),
    attributes => map()
}.

-type sanitize_opts() :: #{
    patterns => [binary()],
    placeholder => binary(),
    preserve => [binary()]
}.

-type comment_opts() :: #{
    format => sql | url | custom,
    prefix => binary(),
    suffix => binary(),
    include_span_id => boolean(),
    include_sampled => boolean()
}.

-export_type([client_system/0, client_opts/0, sanitize_opts/0, comment_opts/0]).

%% ============================================================================
%% Client Span API
%% ============================================================================

%% @doc Executes a function within a client span.
%% The span name is generated from system and operation.
-spec with_client_span(client_system(), operation(), fun(() -> Result)) -> Result
    when Result :: term().
with_client_span(System, Operation, Fun) ->
    with_client_span(System, Operation, #{}, Fun).

%% @doc Executes a function within a client span with options.
-spec with_client_span(client_system(), operation(), client_opts(), fun(() -> Result)) -> Result
    when Result :: term().
with_client_span(System, Operation, Opts, Fun) when is_function(Fun, 0) ->
    SpanName = client_span_name(System, Operation, Opts),
    SpanOpts = build_span_opts(System, Operation, Opts),
    instrument_tracer:with_span(SpanName, SpanOpts, Fun).

%% @doc Starts a client span without executing a function.
%% Remember to call instrument_tracer:end_span/1 when done.
-spec start_client_span(client_system(), operation()) -> #span{}.
start_client_span(System, Operation) ->
    start_client_span(System, Operation, #{}).

%% @doc Starts a client span with options.
-spec start_client_span(client_system(), operation(), client_opts()) -> #span{}.
start_client_span(System, Operation, Opts) ->
    SpanName = client_span_name(System, Operation, Opts),
    SpanOpts = build_span_opts(System, Operation, Opts),
    instrument_tracer:start_span(SpanName, SpanOpts).

%% @doc Generates a span name following semantic conventions.
%% Format: "system operation" or "system operation target"
-spec client_span_name(client_system(), operation()) -> binary().
client_span_name(System, Operation) ->
    client_span_name(System, Operation, #{}).

-spec client_span_name(client_system(), operation(), client_opts()) -> binary().
client_span_name(System, Operation, Opts) ->
    SystemBin = to_binary(System),
    OpBin = to_binary(Operation),
    case maps:get(target, Opts, undefined) of
        undefined ->
            <<SystemBin/binary, " ", OpBin/binary>>;
        Target ->
            TargetBin = to_binary(Target),
            <<SystemBin/binary, " ", OpBin/binary, " ", TargetBin/binary>>
    end.

%% ============================================================================
%% Text Sanitization
%% ============================================================================

%% @doc Sanitizes text by replacing common sensitive patterns.
%% Removes string literals, numbers, and common sensitive patterns.
-spec sanitize_text(binary()) -> binary().
sanitize_text(Text) ->
    sanitize_text(Text, #{}).

%% @doc Sanitizes text with custom options.
%% Patterns are matched and replaced with the placeholder.
%%
%% Options:
%% - patterns: List of regex patterns to replace (default: SQL literals and numbers)
%% - placeholder: Replacement text (default: <<"?">>)
%% - preserve: Patterns to preserve (e.g., <<"\\$\\d+">> for PostgreSQL placeholders)
-spec sanitize_text(binary(), sanitize_opts()) -> binary().
sanitize_text(Text, Opts) when is_binary(Text), is_map(Opts) ->
    Placeholder = maps:get(placeholder, Opts, <<"?">>),
    Patterns = maps:get(patterns, Opts, default_patterns()),
    Preserve = maps:get(preserve, Opts, []),

    %% First, mark patterns to preserve
    {MarkedText, Markers} = mark_preserved(Text, Preserve),

    %% Apply sanitization patterns
    Sanitized = lists:foldl(fun(Pattern, Acc) ->
        apply_pattern(Pattern, Acc, Placeholder)
    end, MarkedText, Patterns),

    %% Restore preserved patterns
    restore_preserved(Sanitized, Markers).

%% ============================================================================
%% Trace Context Injection
%% ============================================================================

%% @doc Injects trace context as a comment into text.
%% Default format is SQL comment: /* traceparent='...' */
-spec inject_trace_comment(binary()) -> binary().
inject_trace_comment(Text) ->
    inject_trace_comment(Text, #{}).

%% @doc Injects trace context with custom format.
%%
%% Options:
%% - format: sql | url | custom (default: sql)
%% - prefix/suffix: Custom delimiters for format => custom
%% - include_span_id: Include span ID (default: false)
%% - include_sampled: Include sampled flag (default: false)
-spec inject_trace_comment(binary(), comment_opts()) -> binary().
inject_trace_comment(Text, Opts) when is_binary(Text), is_map(Opts) ->
    case instrument_tracer:span_ctx() of
        undefined ->
            Text;
        SpanCtx ->
            Comment = format_trace_comment_from_ctx(SpanCtx, Opts),
            Format = maps:get(format, Opts, sql),
            append_comment(Text, Comment, Format, Opts)
    end.

%% @doc Formats the current trace context as a comment string.
-spec format_trace_comment() -> binary().
format_trace_comment() ->
    format_trace_comment(#{}).

%% @doc Formats trace context with options.
-spec format_trace_comment(comment_opts()) -> binary().
format_trace_comment(Opts) ->
    case instrument_tracer:span_ctx() of
        undefined ->
            <<>>;
        SpanCtx ->
            format_trace_comment_from_ctx(SpanCtx, Opts)
    end.

%% ============================================================================
%% Resource Pool Helpers
%% ============================================================================

%% @doc Executes a function with pool acquire/release events in a wrapper span.
%% Creates a single span that contains both pool.acquire and pool.release events,
%% properly capturing the full pool operation lifecycle.
-spec with_pool_span(binary(), client_system(), fun(() -> Result)) -> Result
    when Result :: term().
with_pool_span(PoolName, System, Fun) when is_function(Fun, 0) ->
    SystemBin = to_binary(System),
    SpanName = <<SystemBin/binary, " pool">>,
    instrument_tracer:with_span(SpanName, #{
        kind => client,
        attributes => #{
            <<"pool.name">> => PoolName,
            <<"pool.type">> => SystemBin
        }
    }, fun() ->
        %% Add acquire event at start
        instrument_tracer:add_event(<<"pool.acquire">>, #{
            <<"pool.name">> => PoolName
        }),
        try
            Fun()
        after
            %% Add release event at end (within same span)
            instrument_tracer:add_event(<<"pool.release">>, #{
                <<"pool.name">> => PoolName
            })
        end
    end).

%% @doc Creates a span for pool resource acquisition.
%% The returned span should be ended AFTER the pool operation completes,
%% not immediately after acquisition.
%% Use pool_release_span/1 with the returned span to properly end it.
-spec pool_acquire_span(binary(), client_system()) -> #span{}.
pool_acquire_span(PoolName, System) ->
    SystemBin = to_binary(System),
    SpanName = <<SystemBin/binary, " pool">>,
    Span = instrument_tracer:start_span(SpanName, #{
        kind => client,
        attributes => #{
            <<"pool.name">> => PoolName,
            <<"pool.type">> => SystemBin
        }
    }),
    instrument_tracer:add_event(<<"pool.acquire">>, #{
        <<"pool.name">> => PoolName
    }),
    Span.

%% @doc Records pool resource release and ends the pool span.
%% When called with a span record, adds release event and ends the span.
%% When called with just a pool name (legacy), adds release event to current span.
-spec pool_release_span(binary() | #span{}) -> ok.
pool_release_span(PoolSpan) when is_record(PoolSpan, span) ->
    instrument_tracer:add_event(<<"pool.release">>, #{}),
    instrument_tracer:end_span(PoolSpan);
pool_release_span(PoolName) when is_binary(PoolName) ->
    %% Legacy: just add event if only name provided
    instrument_tracer:add_event(<<"pool.release">>, #{
        <<"pool.name">> => PoolName
    }).

%% ============================================================================
%% Attribute Builders
%% ============================================================================

%% @doc Builds standard attributes from client options.
-spec build_attributes(client_opts()) -> map().
build_attributes(Opts) ->
    System = maps:get(system, Opts, undefined),
    Operation = maps:get(operation, Opts, undefined),
    Target = maps:get(target, Opts, undefined),
    Statement = maps:get(statement, Opts, undefined),
    Sanitize = maps:get(sanitize, Opts, false),
    Extra = maps:get(attributes, Opts, #{}),

    Attrs0 = #{},

    Attrs1 = case System of
        undefined -> Attrs0;
        S ->
            SystemBin = to_binary(S),
            case categorize_system(SystemBin) of
                database -> Attrs0#{<<"db.system">> => SystemBin};
                messaging -> Attrs0#{<<"messaging.system">> => SystemBin};
                rpc -> Attrs0#{<<"rpc.system">> => SystemBin};
                http -> Attrs0;
                _ -> Attrs0
            end
    end,

    Attrs2 = case {Operation, System} of
        {undefined, _} -> Attrs1;
        {Op, S2} ->
            OpBin = to_binary(Op),
            SystemBin2 = to_binary(S2),
            case categorize_system(SystemBin2) of
                database -> Attrs1#{<<"db.operation">> => OpBin};
                messaging -> Attrs1#{<<"messaging.operation">> => OpBin};
                rpc -> Attrs1#{<<"rpc.method">> => OpBin};
                http -> Attrs1#{<<"http.method">> => OpBin};
                _ -> Attrs1
            end
    end,

    Attrs3 = case {Target, System} of
        {undefined, _} -> Attrs2;
        {T, S3} ->
            TargetBin = to_binary(T),
            SystemBin3 = to_binary(S3),
            case categorize_system(SystemBin3) of
                database -> Attrs2#{<<"db.sql.table">> => TargetBin};
                messaging -> Attrs2#{<<"messaging.destination">> => TargetBin};
                http -> Attrs2#{<<"http.target">> => TargetBin};
                _ -> Attrs2
            end
    end,

    Attrs4 = case {Statement, System} of
        {undefined, _} -> Attrs3;
        {Stmt, S4} ->
            StmtBin = to_binary(Stmt),
            FinalStmt = case Sanitize of
                true -> sanitize_text(StmtBin);
                false -> StmtBin
            end,
            SystemBin4 = to_binary(S4),
            case categorize_system(SystemBin4) of
                database -> Attrs3#{<<"db.statement">> => FinalStmt};
                _ -> Attrs3
            end
    end,

    maps:merge(Attrs4, Extra).

%% @doc Sets client attributes on the current span.
-spec set_client_attributes(client_opts()) -> ok.
set_client_attributes(Opts) ->
    Attrs = build_attributes(Opts),
    instrument_tracer:set_attributes(Attrs).

%% @doc Sets response-related attributes on the current span.
%% Accepts: rows_returned, rows_affected, response_size, status_code, etc.
-spec set_response_attributes(map()) -> ok.
set_response_attributes(Attrs) when is_map(Attrs) ->
    Normalized = maps:fold(fun(K, V, Acc) ->
        case K of
            rows_returned -> Acc#{<<"db.rows_returned">> => V};
            rows_affected -> Acc#{<<"db.rows_affected">> => V};
            response_size -> Acc#{<<"http.response_content_length">> => V};
            status_code -> Acc#{<<"http.status_code">> => V};
            message_count -> Acc#{<<"messaging.message_count">> => V};
            _ when is_atom(K) -> Acc#{atom_to_binary(K, utf8) => V};
            _ when is_binary(K) -> Acc#{K => V};
            _ -> Acc
        end
    end, #{}, Attrs),
    instrument_tracer:set_attributes(Normalized).

%% ============================================================================
%% Internal Functions
%% ============================================================================

build_span_opts(System, Operation, Opts) ->
    BaseOpts = #{kind => client},
    Attrs = build_attributes(Opts#{system => System, operation => Operation}),
    BaseOpts#{attributes => Attrs}.

to_binary(V) when is_binary(V) -> V;
to_binary(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_binary(V) when is_list(V) -> list_to_binary(V);
to_binary(V) -> iolist_to_binary(io_lib:format("~p", [V])).

%% Categorize system type for attribute naming
categorize_system(<<"postgresql">>) -> database;
categorize_system(<<"postgres">>) -> database;
categorize_system(<<"mysql">>) -> database;
categorize_system(<<"mariadb">>) -> database;
categorize_system(<<"sqlite">>) -> database;
categorize_system(<<"redis">>) -> database;
categorize_system(<<"mongodb">>) -> database;
categorize_system(<<"cassandra">>) -> database;
categorize_system(<<"mnesia">>) -> database;
categorize_system(<<"ets">>) -> database;
categorize_system(<<"dets">>) -> database;
categorize_system(<<"riak">>) -> database;
categorize_system(<<"couchdb">>) -> database;
categorize_system(<<"elasticsearch">>) -> database;
categorize_system(<<"kafka">>) -> messaging;
categorize_system(<<"rabbitmq">>) -> messaging;
categorize_system(<<"amqp">>) -> messaging;
categorize_system(<<"nats">>) -> messaging;
categorize_system(<<"sqs">>) -> messaging;
categorize_system(<<"sns">>) -> messaging;
categorize_system(<<"pubsub">>) -> messaging;
categorize_system(<<"grpc">>) -> rpc;
categorize_system(<<"thrift">>) -> rpc;
categorize_system(<<"http">>) -> http;
categorize_system(<<"https">>) -> http;
categorize_system(_) -> other.

%% Default sanitization patterns for SQL
default_patterns() ->
    [
        %% Single-quoted strings
        <<"'[^']*'">>,
        %% Double-quoted strings
        <<"\"[^\"]*\"">>,
        %% Numbers (integers and floats, but not in identifiers)
        <<"\\b\\d+\\.?\\d*\\b">>,
        %% Hexadecimal values
        <<"0x[0-9a-fA-F]+">>
    ].

%% Mark patterns that should be preserved
mark_preserved(Text, []) ->
    {Text, []};
mark_preserved(Text, Patterns) ->
    lists:foldl(fun(Pattern, {Acc, Markers}) ->
        case re:run(Acc, Pattern, [global, {capture, all, binary}]) of
            {match, Matches} ->
                mark_matches(Acc, Markers, Matches, Pattern);
            nomatch ->
                {Acc, Markers}
        end
    end, {Text, []}, Patterns).

mark_matches(Text, Markers, Matches, _Pattern) ->
    lists:foldl(fun([Match], {Acc, M}) ->
        Marker = <<"__PRESERVE_", (integer_to_binary(length(M)))/binary, "__">>,
        NewAcc = binary:replace(Acc, Match, Marker, []),
        {NewAcc, [{Marker, Match} | M]}
    end, {Text, Markers}, Matches).

%% Restore preserved patterns
restore_preserved(Text, []) ->
    Text;
restore_preserved(Text, [{Marker, Original} | Rest]) ->
    NewText = binary:replace(Text, Marker, Original, [global]),
    restore_preserved(NewText, Rest).

%% Apply a sanitization pattern
apply_pattern(Pattern, Text, Placeholder) ->
    case re:run(Text, Pattern, [global]) of
        {match, _} ->
            re:replace(Text, Pattern, Placeholder, [global, {return, binary}]);
        nomatch ->
            Text
    end.

%% Format trace comment from span context
format_trace_comment_from_ctx(#span_ctx{trace_id = TraceId, span_id = SpanId, trace_flags = Flags}, Opts) ->
    TraceIdHex = instrument_id:trace_id_to_hex(TraceId),
    SpanIdHex = instrument_id:span_id_to_hex(SpanId),
    Sampled = case Flags band 1 of 1 -> <<"01">>; 0 -> <<"00">> end,

    %% W3C traceparent format: version-traceid-spanid-flags
    Traceparent = <<"00-", TraceIdHex/binary, "-", SpanIdHex/binary, "-", Sampled/binary>>,

    IncludeSpanId = maps:get(include_span_id, Opts, false),
    IncludeSampled = maps:get(include_sampled, Opts, false),

    Parts = [<<"traceparent='", Traceparent/binary, "'">>],
    Parts2 = case IncludeSpanId of
        true -> Parts ++ [<<"spanid='", SpanIdHex/binary, "'">>];
        false -> Parts
    end,
    Parts3 = case IncludeSampled of
        true -> Parts2 ++ [<<"sampled='", Sampled/binary, "'">>];
        false -> Parts2
    end,

    iolist_to_binary(lists:join(<<",">>, Parts3)).

%% Append comment in the appropriate format
append_comment(Text, Comment, sql, _Opts) ->
    <<Text/binary, " /*", Comment/binary, "*/">>;
append_comment(Text, Comment, url, _Opts) ->
    %% URL encoding for trace context
    Encoded = uri_encode(Comment),
    Separator = case binary:match(Text, <<"?">>) of
        nomatch -> <<"?">>;
        _ -> <<"&">>
    end,
    <<Text/binary, Separator/binary, Encoded/binary>>;
append_comment(Text, Comment, custom, Opts) ->
    Prefix = maps:get(prefix, Opts, <<"">>),
    Suffix = maps:get(suffix, Opts, <<"">>),
    <<Text/binary, " ", Prefix/binary, Comment/binary, Suffix/binary>>.

%% Simple URI encoding for trace context
uri_encode(Bin) ->
    %% For traceparent, we just need to encode the quotes
    binary:replace(Bin, <<"'">>, <<"%27">>, [global]).
