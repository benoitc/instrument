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
    case instrument_sup:start_link() of
        {ok, Pid} ->
            %% Only register legacy exporters if no span processor is configured
            %% to avoid dual export (spans exported by both paths)
            case instrument_config:has_span_processor_config() of
                true -> ok;
                false -> instrument_config:auto_register_exporters()
            end,
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
