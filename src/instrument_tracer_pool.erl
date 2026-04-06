%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Supervisor for flight tracer worker pool.
%%
%% This module manages a pool of flight tracer workers. The pool size
%% defaults to the number of schedulers for optimal parallelism. Workers
%% are started on-demand when tracing is enabled.
%%
%% The pool maintains a map of worker indices to pids that is used by
%% the tracer NIF to distribute events via hash-based assignment.
-module(instrument_tracer_pool).
-author("benoitc").

-behaviour(supervisor).

%% API
-export([
  start_link/0,
  start_pool/0,
  stop_pool/0,
  get_tracer_state/1,
  pool_size/0
]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).
-define(POOL_SIZE_KEY, '$instrument_tracer_pool_size').
-define(WORKERS_KEY, '$instrument_tracer_workers').

%% ============================================================================
%% API
%% ============================================================================

%% @doc Starts the pool supervisor.
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
  supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% @doc Starts all workers in the pool.
%% Idempotent - does nothing if pool is already running.
-spec start_pool() -> ok.
start_pool() ->
  %% Check if pool is already running
  case persistent_term:get(?POOL_SIZE_KEY, 0) of
    0 ->
      %% Pool not running, start it
      PoolSize = pool_size(),
      WorkersList = lists:map(fun(Index) ->
        {ok, Pid} = supervisor:start_child(?SERVER, [Index]),
        {Index, Pid}
      end, lists:seq(0, PoolSize - 1)),
      Workers = maps:from_list(WorkersList),
      persistent_term:put(?POOL_SIZE_KEY, PoolSize),
      persistent_term:put(?WORKERS_KEY, Workers),
      ok;
    _ ->
      %% Pool already running
      ok
  end.

%% @doc Stops all workers in the pool.
-spec stop_pool() -> ok.
stop_pool() ->
  %% Clear persistent terms first to prevent new traces
  persistent_term:put(?POOL_SIZE_KEY, 0),
  persistent_term:put(?WORKERS_KEY, #{}),
  %% Terminate all children
  Children = supervisor:which_children(?SERVER),
  lists:foreach(fun({_, Pid, _, _}) ->
    supervisor:terminate_child(?SERVER, Pid)
  end, Children),
  ok.

%% @doc Gets the tracer state map for erlang:trace.
%% Returns a map with pool_size, workers, and label.
-spec get_tracer_state(integer()) -> map().
get_tracer_state(Label) ->
  #{
    pool_size => persistent_term:get(?POOL_SIZE_KEY, 0),
    workers => persistent_term:get(?WORKERS_KEY, #{}),
    label => Label
  }.

%% @doc Returns the configured pool size.
-spec pool_size() -> pos_integer().
pool_size() ->
  application:get_env(instrument, flight_recorder_pool_size,
    erlang:system_info(schedulers)).

%% ============================================================================
%% Supervisor callbacks
%% ============================================================================

init([]) ->
  %% Initialize persistent terms
  persistent_term:put(?POOL_SIZE_KEY, 0),
  persistent_term:put(?WORKERS_KEY, #{}),

  SupFlags = #{
    strategy => simple_one_for_one,
    intensity => 10,
    period => 10
  },
  ChildSpec = #{
    id => flight_tracer,
    start => {instrument_flight_tracer, start_link, []},
    restart => temporary,
    shutdown => 5000,
    type => worker,
    modules => [instrument_flight_tracer]
  },
  {ok, {SupFlags, [ChildSpec]}}.
