%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @private Owns one exporter for a synchronous span processor.
%%
%% The simple and tail-sampling processors run `on_end' in the process that
%% ends the span. Calling the exporter directly from there meant concurrent
%% calls into one exporter (which the OpenTelemetry spec forbids) and
%% exporter state rewritten in `persistent_term' on every span. This server
%% holds the exporter state instead: `on_end' calls it, so exports are
%% serialized and the caller still waits for its span to be exported.
-module(instrument_export_server).

-behaviour(gen_server).

-export([
  start/4,
  stop/1,
  export/3,
  force_flush/2
]).

-export([
  init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3
]).

-record(state, {
  exporter :: module(),
  exporter_state :: term()
}).

%% @doc Starts a server registered as `Name' for `Exporter', supervised by
%% instrument_sup when it is running.
-spec start(atom(), module(), map(), pos_integer()) -> ok | {error, term()}.
start(Name, Exporter, ExporterConfig, Timeout) ->
  Spec = #{
    id => {?MODULE, Name},
    start => {gen_server, start_link,
              [{local, Name}, ?MODULE, {Exporter, ExporterConfig}, []]},
    restart => transient,
    shutdown => Timeout + 5000,
    type => worker,
    modules => [?MODULE]
  },
  _ = stop(Name),
  Result = case whereis(instrument_sup) of
             undefined ->
               gen_server:start({local, Name}, ?MODULE, {Exporter, ExporterConfig}, []);
             _ ->
               supervisor:start_child(instrument_sup, Spec)
           end,
  case Result of
    {ok, _Pid} -> ok;
    {error, Reason} -> {error, Reason}
  end.

%% @doc Shuts the exporter down and stops the server.
-spec stop(atom()) -> ok.
stop(Name) ->
  case whereis(instrument_sup) of
    undefined ->
      instrument_lib:safe_call(fun() -> gen_server:stop(Name) end, ok);
    _ ->
      _ = supervisor:terminate_child(instrument_sup, {?MODULE, Name}),
      _ = supervisor:delete_child(instrument_sup, {?MODULE, Name}),
      %% Started outside the supervisor (before it was running)
      instrument_lib:safe_call(fun() -> gen_server:stop(Name) end, ok)
  end,
  ok.

%% @doc Exports `Spans' and waits for the result. Returns `ok' even when the
%% server is missing or the export times out.
-spec export(atom(), [term()], timeout()) -> ok.
export(Name, Spans, Timeout) ->
  instrument_lib:safe_call(fun() -> gen_server:call(Name, {export, Spans}, Timeout) end, ok).

-spec force_flush(atom(), timeout()) -> ok.
force_flush(Name, Timeout) ->
  instrument_lib:safe_call(fun() -> gen_server:call(Name, force_flush, Timeout) end, ok).

%% ============================================================================
%% gen_server callbacks
%% ============================================================================

init({Exporter, ExporterConfig}) ->
  %% Trap exits so terminate/2 shuts the exporter down on supervisor stop.
  process_flag(trap_exit, true),
  case Exporter:init(ExporterConfig) of
    {ok, ExporterState} ->
      {ok, #state{exporter = Exporter, exporter_state = ExporterState}};
    {error, Reason} ->
      {stop, Reason}
  end.

handle_call({export, Spans}, _From, #state{exporter = E, exporter_state = S} = State) ->
  NewS = try E:export(Spans, S) of
           {ok, S1} -> S1;
           {error, _Reason, S1} -> S1;
           _ -> S
         catch
           Class:Reason:Stack ->
             logger:warning("Span export to ~p failed: ~p:~p",
                            [E, Class, Reason],
                            #{mfa => {E, export, 2}, stacktrace => Stack}),
             S
         end,
  {reply, ok, State#state{exporter_state = NewS}};

handle_call(force_flush, _From, #state{exporter = E, exporter_state = S} = State) ->
  NewS = case instrument_lib:safe_apply(E, force_flush, [S], S) of
           {ok, S1} -> S1;
           _ -> S
         end,
  {reply, ok, State#state{exporter_state = NewS}};

handle_call(_Request, _From, State) ->
  {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, #state{exporter = E, exporter_state = S}) ->
  instrument_lib:safe_apply(E, shutdown, [S], ok),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.
