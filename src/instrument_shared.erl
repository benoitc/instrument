%%%-------------------------------------------------------------------
%%% @author benoitc
%%% @copyright (C) 2017, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 02. May 2017 14:00
%%%-------------------------------------------------------------------
-module(instrument_shared).
-author("benoitc").

%% API
-export([
  start_link/0,
  reg/1,
  unreg/1,
  with/2,
  with_label/3,
  with_vector/2
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, code_change/3, terminate/2]).

-include("instrument.hrl").


reg(Metric) ->
  gen_server:call(?MODULE, {reg, Metric}).

unreg(Name) ->
  gen_server:call(?MODULE, {unreg, Name}).


with(Name, Fun) ->
  case ets:lookup(?MODULE, Name) of
    [#metric{}=Metric] ->
      instrument_lib:apply_fun(Fun, Metric);
    [] ->
      {error, not_found}
  end.

with_vector(Name, Fun) ->
  case ets:lookup(?MODULE, Name) of
    [#metric{}=Metric] ->
      instrument_vector:with(Metric, Fun);
    [] ->
      {error, not_found}
  end.

with_label(Name, Label, Fun) ->
  case ets:lookup(?MODULE, Name) of
    [#metric{}=VectorMetric] ->
      case instrument_vector:has_label(VectorMetric, Label) of
        true ->
          instrument_vector:with_label(VectorMetric, Label, Fun);
        false ->
          ok = gen_server:call(?MODULE, {maybe_create_metric, Name, Label}),
          with_label(Name, Label, Fun)
      end;
    [] ->
      {error, not_found}
  end.


start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
  _ = ets:new(
    ?MODULE, [ordered_set, public, named_table, {read_concurrency, true}, {keypos, #metric.name}]
  ),
  {ok, []}.

handle_call({maybe_create_metric, Name, Label}, _From, State) ->
  Reply = case ets:lookup(?MODULE, Name) of
            [] -> {error, not_found};
            [#metric{handle=Vector}=M] ->
              {_, Vector2} = instrument_vector:maybe_create_metric(Label, Vector),
              _ = ets:insert(?MODULE, M#metric{handle=Vector2}),
              ok
          end,
  {reply, Reply, State};

handle_call({reg, Metric}, _From, State) ->
  Reply = do_reg(Metric),
  {reply, Reply, State};

handle_call({unreg, Name}, _From, State) ->
  _ = do_unreg(Name),
  {reply, ok, State};

handle_call(Req, _From, State) ->
  {stop, {unhandled_call, Req}, State}.

handle_cast(Msg, State) ->
  {stop, {unhandled_cast, Msg}, State}.

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

do_reg(Metric) ->
  ets:insert_new(?MODULE, Metric).

do_unreg(Name) ->
  _ = ets:delete(?MODULE, Name),
  _ = erlang:garbage_collect(self()),
  ok.