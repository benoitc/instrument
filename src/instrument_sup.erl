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
-define(EXPORT_SHUTDOWN, 35000).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
  supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

%% rest_for_one: a crashed child is restarted together with the children
%% started after it, which may depend on it. The table owner comes first and
%% holds the shared ETS tables, so restarting the registry or an exporter
%% keeps metrics and registrations. Ten restarts within a minute stop the
%% application.
init([]) ->
  TableOwner = child_spec(worker, table_owner, instrument_table_owner, permanent, []),
  Registry = child_spec(worker, registry, instrument_registry, permanent, []),
  %% Exporters drain on shutdown: allow one export plus margin.
  Exporter = (child_spec(worker, exporter, instrument_exporter, permanent, []))#{
               shutdown => ?EXPORT_SHUTDOWN},
  MetricsExporter = child_spec(worker, metrics_exporter, instrument_metrics_exporter, permanent, []),
  LogExporter = (child_spec(worker, log_exporter, instrument_log_exporter, permanent, []))#{
                  shutdown => ?EXPORT_SHUTDOWN},
  SpanProcessor = child_spec(worker, span_processor, instrument_span_processor, permanent, []),
  TracerPool = child_spec(supervisor, tracer_pool, instrument_tracer_pool, permanent, []),
  FlightRecorder = child_spec(worker, flight_recorder, instrument_flight_recorder, permanent, []),
  SupFlags = #{strategy => rest_for_one, intensity => 10, period => 60},
  {ok, {SupFlags, [TableOwner, Registry, Exporter, MetricsExporter, LogExporter,
                   SpanProcessor, TracerPool, FlightRecorder]}}.

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
