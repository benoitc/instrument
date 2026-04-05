%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Log exporter for testing - stores logs in ETS for assertion.
%% @private
-module(instrument_test_log_exporter).
-author("benoitc").

-export([
    init/1,
    export/2,
    shutdown/1,
    force_flush/1
]).

-include("instrument_otel.hrl").

-define(DEFAULT_TAB, instrument_test_logs).

%% @doc Initializes the exporter with config.
init(Config) ->
    Tab = maps:get(table, Config, ?DEFAULT_TAB),
    {ok, #{table => Tab}}.

%% @doc Exports log records to ETS table.
export(LogRecords, #{table := Tab} = State) ->
    case ets:info(Tab) of
        undefined ->
            {ok, State};
        _ ->
            lists:foreach(fun(LogRecord) ->
                ets:insert(Tab, {log, LogRecord})
            end, LogRecords),
            {ok, State}
    end.

%% @doc Shuts down the exporter.
shutdown(_State) ->
    ok.

%% @doc Forces a flush (no-op for ETS).
force_flush(State) ->
    {ok, State}.
