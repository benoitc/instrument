%%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%%====================================================================
%% API
%%====================================================================

start(_StartType, _StartArgs) ->
    ok = instrument_config:init(),
    %% Create ETS table for span exporters (atomic operations)
    _ = ets:new(instrument_span_exporters, [
        public, named_table, bag,
        {read_concurrency, true},
        {write_concurrency, true}
    ]),
    %% Initialize exporter cache (empty list initially)
    persistent_term:put('$instrument_exporters', []),
    case instrument_sup:start_link() of
        {ok, Pid} ->
            %% Traces go through the batch span processor; the span exporter
            %% only gets extra trace exporters, so no span is exported twice.
            instrument_config:auto_register_exporters(),
            instrument_config:auto_register_span_processor(),
            {ok, Pid};
        Error ->
            Error
    end.

%%--------------------------------------------------------------------
stop(_State) ->
    ok.

%%====================================================================
%% Internal functions
%%====================================================================
