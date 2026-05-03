%% Test helper: a gen_server that unwraps `{'$instrument_call', Ctx, Req}`
%% and `{'$instrument_cast', Ctx, Msg}` envelopes, attaches the context,
%% and reports the trace_id it observes. Used by
%% instrument_propagator_SUITE to exercise call_with_context/cast_with_context.
-module(ctx_echo_server).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

start_link() ->
  gen_server:start_link(?MODULE, [], []).

init([]) ->
  {ok, #{}}.

handle_call({'$instrument_call', Ctx, who_am_i}, _From, State) ->
  Token = instrument_context:attach(Ctx),
  try
    Reply = case instrument_tracer:trace_id() of
      undefined -> no_span;
      Hex -> {trace_id, Hex}
    end,
    {reply, Reply, State}
  after
    instrument_context:detach(Token)
  end;
handle_call(who_am_i, _From, State) ->
  Reply = case instrument_tracer:trace_id() of
    undefined -> no_span;
    Hex -> {trace_id, Hex}
  end,
  {reply, Reply, State};
handle_call(_Other, _From, State) ->
  {reply, ok, State}.

handle_cast({'$instrument_cast', Ctx, {report_to, Pid}}, State) ->
  Token = instrument_context:attach(Ctx),
  try
    Hex = instrument_tracer:trace_id(),
    Pid ! {ctx_seen, Hex},
    {noreply, State}
  after
    instrument_context:detach(Token)
  end;
handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_Old, State, _Extra) ->
  {ok, State}.
