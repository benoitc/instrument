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
%% Workers are registered as `instrument_flight_tracer_<N>'. The tracer NIF
%% hashes the tracee to pick a worker, resolves it by name, and drops the
%% event when that worker already has `flight_recorder_max_queue' events
%% queued, so a burst of traced messages cannot grow mailboxes without bound.
-module(instrument_tracer_pool).
-author("benoitc").

-behaviour(supervisor).

%% API
-export([
  start_link/0,
  start_pool/0,
  stop_pool/0,
  get_tracer_state/1,
  pool_size/0,
  max_queue/0,
  counters/0,
  stats/0,
  worker_name/1
]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).
-define(POOL_SIZE_KEY, '$instrument_tracer_pool_size').
-define(WORKERS_KEY, '$instrument_tracer_workers').
-define(COUNTERS_KEY, '$instrument_tracer_counters').
-define(MAX_POOL_SIZE, 1024).
-define(DEFAULT_MAX_QUEUE, 1000).
-define(MAX_PAYLOAD_KEY, '$instrument_tracer_max_payload').

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
  case persistent_term:get(?POOL_SIZE_KEY, 0) of
    0 ->
      PoolSize = pool_size(),
      Counters = counters(),
      Names = [worker_name(Index) || Index <- lists:seq(0, PoolSize - 1)],
      lists:foreach(fun(Index) ->
        case supervisor:start_child(?SERVER, [Index, Counters]) of
          {ok, _Pid} -> ok;
          {error, {already_started, _Pid}} -> ok
        end
      end, lists:seq(0, PoolSize - 1)),
      persistent_term:put(?WORKERS_KEY, list_to_tuple(Names)),
      persistent_term:put(?POOL_SIZE_KEY, PoolSize),
      ok;
    _ ->
      ok
  end.

%% @doc Stops all workers in the pool.
-spec stop_pool() -> ok.
stop_pool() ->
  %% Clear the pool size first so new tracer states stop routing events
  persistent_term:put(?POOL_SIZE_KEY, 0),
  Children = supervisor:which_children(?SERVER),
  lists:foreach(fun({_, Pid, _, _}) ->
    supervisor:terminate_child(?SERVER, Pid)
  end, Children),
  ok.

%% @doc Gets the tracer state map for erlang:trace.
%% Workers are given by registered name so a restarted worker keeps
%% receiving events; `counters' bounds how many events each worker queues.
-spec get_tracer_state(integer()) -> map().
get_tracer_state(Label) ->
  #{
    pool_size => persistent_term:get(?POOL_SIZE_KEY, 0),
    workers => persistent_term:get(?WORKERS_KEY, {}),
    counters => counters(),
    max_payload => persistent_term:get(?MAX_PAYLOAD_KEY, 1024),
    label => Label
  }.

%% @doc Returns the configured pool size (`flight_recorder_pool_size',
%% 1 to 1024, default: number of schedulers).
-spec pool_size() -> pos_integer().
pool_size() ->
  instrument_lib:bounded_env(flight_recorder_pool_size,
                             erlang:system_info(schedulers), 1, ?MAX_POOL_SIZE).

%% @doc Returns the per-worker queue limit (`flight_recorder_max_queue',
%% default 1000).
-spec max_queue() -> pos_integer().
max_queue() ->
  instrument_lib:bounded_env(flight_recorder_max_queue, ?DEFAULT_MAX_QUEUE,
                             1, 1 bsl 30).

%% @doc Returns the shared queue counters.
-spec counters() -> reference() | undefined.
counters() ->
  persistent_term:get(?COUNTERS_KEY, undefined).

%% @doc Returns `#{dropped, queued, max}' for the pool.
-spec stats() -> map().
stats() ->
  case counters() of
    undefined -> #{dropped => 0, queued => 0, max => max_queue()};
    Counters -> instrument_tracer_nif:pool_counters(Counters)
  end.

%% @doc Registered name of worker `Index'.
-spec worker_name(non_neg_integer()) -> atom().
worker_name(Index) ->
  list_to_atom("instrument_flight_tracer_" ++ integer_to_list(Index)).

%% ============================================================================
%% Supervisor callbacks
%% ============================================================================

init([]) ->
  %% Counters are sized for the configured pool and live as long as this
  %% supervisor, so tracer states captured before a worker restart stay valid.
  persistent_term:put(?COUNTERS_KEY,
                      instrument_tracer_nif:new_pool_counters(pool_size(), max_queue())),
  persistent_term:put(?MAX_PAYLOAD_KEY, instrument_flight_tracer:max_payload()),
  persistent_term:put(?POOL_SIZE_KEY, 0),
  persistent_term:put(?WORKERS_KEY, {}),

  %% Allow every worker to restart a few times before giving up.
  SupFlags = #{
    strategy => simple_one_for_one,
    intensity => max(10, 3 * pool_size()),
    period => 10
  },
  ChildSpec = #{
    id => flight_tracer,
    start => {instrument_flight_tracer, start_link, []},
    restart => permanent,
    shutdown => 5000,
    type => worker,
    modules => [instrument_flight_tracer]
  },
  {ok, {SupFlags, [ChildSpec]}}.
