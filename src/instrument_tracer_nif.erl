%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc NIF module implementing the erl_tracer behavior.
%%
%% This module provides the callback functions required by erlang:trace/3
%% when using a custom tracer. The NIF distributes trace events to a pool
%% of worker processes using hash-based assignment on the tracee pid.
%%
%% Reference: https://www.erlang.org/doc/apps/erts/erl_tracer.html
%%
%% TracerState is a map containing:
%% - pool_size: number of workers
%% - workers: map of index to worker pid (#{0 => Pid1, 1 => Pid2, ...})
%% - label: trace label (usually trace_id as integer)
-module(instrument_tracer_nif).
-author("benoitc").

%% Required erl_tracer callbacks
-export([
  enabled/3,
  trace/5
]).

%% Session resource management for child process cleanup
-export([
  create_session_resource/0,
  deactivate_session_resource/1
]).

%% Optional specialized enabled callbacks
-export([
  enabled_send/3,
  enabled_receive/3,
  enabled_spawn/3,
  enabled_procs/3,
  enabled_running_procs/3,
  enabled_call/3,
  enabled_garbage_collection/3
]).

%% Optional specialized trace callbacks
-export([
  trace_send/5,
  trace_receive/5,
  trace_spawn/5,
  trace_procs/5
]).

-on_load(init/0).

init() ->
  SoName = case code:priv_dir(instrument) of
    {error, bad_name} ->
      case code:which(?MODULE) of
        Filename when is_list(Filename) ->
          filename:join([filename:dirname(Filename), "../priv", "instrument_tracer_nif"]);
        _ ->
          filename:join("../priv", "instrument_tracer_nif")
      end;
    Dir ->
      filename:join(Dir, "instrument_tracer_nif")
  end,
  erlang:load_nif(SoName, []).

%% ============================================================================
%% Required erl_tracer callbacks
%% ============================================================================

%% @doc Check if tracing is enabled for the given tracee.
%% Called before trace/5 to determine if we should trace.
%% Returns: trace | discard | remove
-spec enabled(atom(), map(), pid() | port() | undefined) -> trace | discard | remove.
enabled(_TraceTag, _TracerState, _Tracee) ->
  erlang:nif_error({error, not_loaded}).

%% @doc Handle a trace event.
%% Hashes the tracee pid to select a worker and forwards the event.
-spec trace(atom(), map(), pid() | port() | undefined, term(), map()) -> ok.
trace(_TraceTag, _TracerState, _Tracee, _TraceTerm, _Opts) ->
  erlang:nif_error({error, not_loaded}).

%% ============================================================================
%% Session Resource Management
%% ============================================================================

%% @doc Create a new session resource for tracking active tracing sessions.
%% Returns a resource reference that can be included in tracer state.
%% Spawned children inherit this reference via set_on_spawn.
-spec create_session_resource() -> reference().
create_session_resource() ->
  erlang:nif_error({error, not_loaded}).

%% @doc Deactivate a session resource.
%% Called when parent span ends. Children will see the inactive session
%% on their next trace event and return 'remove' to stop tracing.
-spec deactivate_session_resource(reference()) -> ok.
deactivate_session_resource(_SessionRef) ->
  erlang:nif_error({error, not_loaded}).

%% ============================================================================
%% Specialized enabled callbacks
%% ============================================================================

%% @doc Check if send tracing is enabled.
-spec enabled_send(atom(), map(), pid() | port()) -> trace | discard | remove.
enabled_send(_TraceTag, _TracerState, _Tracee) ->
  erlang:nif_error({error, not_loaded}).

%% @doc Check if receive tracing is enabled.
-spec enabled_receive(atom(), map(), pid() | port()) -> trace | discard | remove.
enabled_receive(_TraceTag, _TracerState, _Tracee) ->
  erlang:nif_error({error, not_loaded}).

%% @doc Check if spawn tracing is enabled.
-spec enabled_spawn(atom(), map(), pid() | port()) -> trace | discard | remove.
enabled_spawn(_TraceTag, _TracerState, _Tracee) ->
  erlang:nif_error({error, not_loaded}).

%% @doc Check if procs tracing is enabled.
-spec enabled_procs(atom(), map(), pid() | port()) -> trace | discard | remove.
enabled_procs(_TraceTag, _TracerState, _Tracee) ->
  erlang:nif_error({error, not_loaded}).

%% @doc Check if running_procs tracing is enabled.
-spec enabled_running_procs(atom(), map(), pid() | port()) -> trace | discard | remove.
enabled_running_procs(_TraceTag, _TracerState, _Tracee) ->
  erlang:nif_error({error, not_loaded}).

%% @doc Check if call tracing is enabled.
-spec enabled_call(atom(), map(), pid() | port()) -> trace | discard | remove.
enabled_call(_TraceTag, _TracerState, _Tracee) ->
  erlang:nif_error({error, not_loaded}).

%% @doc Check if garbage_collection tracing is enabled.
-spec enabled_garbage_collection(atom(), map(), pid() | port()) -> trace | discard | remove.
enabled_garbage_collection(_TraceTag, _TracerState, _Tracee) ->
  erlang:nif_error({error, not_loaded}).

%% ============================================================================
%% Specialized trace callbacks
%% ============================================================================

%% @doc Handle a send trace event.
-spec trace_send(atom(), map(), pid(), term(), map()) -> ok.
trace_send(_TraceTag, _TracerState, _Tracee, _TraceTerm, _Opts) ->
  erlang:nif_error({error, not_loaded}).

%% @doc Handle a receive trace event.
-spec trace_receive(atom(), map(), pid(), term(), map()) -> ok.
trace_receive(_TraceTag, _TracerState, _Tracee, _TraceTerm, _Opts) ->
  erlang:nif_error({error, not_loaded}).

%% @doc Handle a spawn trace event.
-spec trace_spawn(atom(), map(), pid(), term(), map()) -> ok.
trace_spawn(_TraceTag, _TracerState, _Tracee, _TraceTerm, _Opts) ->
  erlang:nif_error({error, not_loaded}).

%% @doc Handle a procs trace event.
-spec trace_procs(atom(), map(), pid(), term(), map()) -> ok.
trace_procs(_TraceTag, _TracerState, _Tracee, _TraceTerm, _Opts) ->
  erlang:nif_error({error, not_loaded}).
