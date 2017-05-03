%% Copyright (c) 2017, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_registry).
-author("benoitc").

%% API
-export([
  start_link/0,
  register/1,
  unregister/1,
  unregister_all/0,
  with/2, with/3, with/4, with/5
]).

-export([
  remove_label/2,
  clear_labels/1,
  create_vector_metric/2
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, code_change/3, terminate/2]).

-include("instrument.hrl").

%% API

start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

register(Metric) ->
  gen_server:call(?MODULE, {reg, Metric}).

unregister(Name) ->
  gen_server:call(?MODULE, {unreg, Name}).

unregister_all() ->
  gen_server:call(?MODULE, unregister_all).


with(Metric, Fun) -> with_1(Metric, Fun, []).
with(Metric, Fun, A) -> with_1(Metric, Fun, [A]).
with(Metric, Fun, A1, A2) -> with_1(Metric, Fun, [A1, A2]).
with(Metric, Fun, A1, A2, A3) -> with_1(Metric, Fun, [A1, A2, A3]).


with_1(#metric{name=Name, handle=#vector{}}, Fun, Args) ->
  with_1(Name, Fun, Args);
with_1(#metric{}=M, Fun, Args) ->
  erlang:apply(Fun, [M |Args]);
with_1(Metric, Fun, Args) ->
  case ets:lookup(instrument_lib:table(), Metric) of
    [#metric{}=M] -> erlang:apply(Fun, [M |Args]);
    [] -> {error, not_found}
  end.


%% INTERNAL VECTOR API

remove_label(Name, Label) ->
  gen_server:call(?MODULE, {remove_label, Name, Label}).

clear_labels(Name) ->
  gen_server:call(?MODULE, {clear_labels, Name}).

create_vector_metric(Name, Label) ->
  gen_server:call(?MODULE, {create_vector_metric, Name, Label}).


%% gen_server callbacks

init([]) ->
  _ = create_tables(),
  {ok, []}.


create_tables() ->
  [ets:new(T, [public, named_table, set, {keypos,#metric.name}]) || T <- tables()].

handle_call({reg, #metric{name=N}=Metric}, _From, State) ->
  Reply = case ets:member(instrument_lib:table(), N) of
            true ->
              {error, already_exists};
            false ->
              _ = do_reg(Metric),
              ok
          
          end,
  {reply, Reply, State};

handle_call({unreg, Name}, _From, State) ->
  _ = do_unreg(Name),
  {reply, ok, State};

handle_call(unregister_all, _From, State) ->
  _Res = do_delete_all(),
  _ = erlang:garbage_collect(self()),
  {reply, ok, State};


handle_call({create_vector_metric, Name, Label}, _From, State) ->
  Reply = case ets:lookup(instrument_lib:table(), Name) of
            [] -> ok;
            [Metric] ->
              Metric2 = do_create_metric(Metric, Label),
              _ = do_reg(Metric2),
              ok
          end,
  {reply, Reply, State};

handle_call({remove_label, Name, Label}, _From, State) ->
  Reply = case ets:lookup(instrument_lib:table(), Name) of
            [] -> ok;
            [Metric] ->
              Metric2 = do_remove_label(Metric, Label),
              _ = do_reg(Metric2),
              ok
          end,
  {reply, Reply, State};

handle_call({clear_labels, Name}, _From, State) ->
  Reply = case ets:lookup(instrument_lib:table(), Name) of
            [] -> ok;
            [Metric] ->
              Metric2 = do_clear_labels(Metric),
              _ = do_reg(Metric2),
              ok
          end,
  {reply, Reply, State};

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
  [ets:insert(T, Metric) || T <- tables()].

do_unreg(Name) ->
  _ = ets:delete(?MODULE, Name),
  ok.

do_delete_all() ->
  [ets:delete_all_objects(T) || T <- instrument_lib:tables()].


tables() -> instrument_lib:tables().


do_create_metric(Metric, Label) ->
  #metric{ handle = Vector } = Metric,
  #vector{ labels_map = LabelsMap } = Vector,
  case maps:find(Label, LabelsMap) of
    {ok, _} -> Metric;
    error ->
      M = mk_metric(Vector),
      Vector2 = Vector#vector{labels_map=maps:put(Label, M, LabelsMap)},
      Metric#metric{handle=Vector2}
  end.

mk_metric(#vector{ name=Name, help=Help, metric=counter }) ->
  instrument_counter:new_counter(Name, Help);
mk_metric(#vector{ name=Name, help=Help, metric=gauge }) ->
  instrument_gauge:new_gauge(Name, Help);
mk_metric(#vector{ name=Name, help=Help, metric=histogram, buckets=Buckets }) ->
  instrument_histogram:new_histogram(Name, Help, Buckets).

do_remove_label(#metric{ handle = Vector } = Metric, Label) ->
  #vector{ labels_map = LabelsMap } = Vector,
  Vector2 = Vector#vector{labels_map=maps:remove(Label, LabelsMap)},
  Metric#metric{handle=Vector2}.

do_clear_labels(#metric{ handle = Vector } = Metric) ->
  Vector2 = Vector#vector{labels_map=#{}},
  Metric#metric{handle=Vector2}.