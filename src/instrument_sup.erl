%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
  supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

%% Child :: {Id,StartFunc,Restart,Shutdown,Type,Modules}
init([]) ->
  Registry = child_spec(worker, registry, instrument_registry, permanent, []),
  Exporter = child_spec(worker, exporter, instrument_exporter, permanent, []),
  MetricsExporter = child_spec(worker, metrics_exporter, instrument_metrics_exporter, permanent, []),
  LogExporter = child_spec(worker, log_exporter, instrument_log_exporter, permanent, []),
  SpanProcessor = child_spec(worker, span_processor, instrument_span_processor, permanent, []),
  FlightRecorder = child_spec(worker, flight_recorder, instrument_flight_recorder, permanent, []),
  {ok, { {one_for_all, 0, 1}, [Registry, Exporter, MetricsExporter, LogExporter, SpanProcessor, FlightRecorder]} }.

%%====================================================================
%% Internal functions
%%====================================================================


child_spec(WorkerOrSupervisor, N, I, Restart, Args) ->
  #{
    id => N,
    start => {I, start_link, Args},
    restart => Restart,
    shutdown => 5000,
    type => WorkerOrSupervisor,
    modules => [I]
  }.
