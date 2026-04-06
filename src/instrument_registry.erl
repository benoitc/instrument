%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
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
  with/2
]).

-export([
  remove_label/2,
  clear_labels/1,
  create_vector_metric/2
]).

%% persistent_term based lookup API
-export([
  lookup/1,
  lookup_label/2,
  cache_label/3,
  collect_all/0
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, code_change/3, terminate/2]).

-include("instrument.hrl").

%% State record - metrics_set is the source of truth for registered metric names
-record(state, {
  metrics_set = sets:new() :: sets:set(term())
}).

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
  %% Initialize persistent_term index as empty
  persistent_term:put(instrument_metrics, []),
  {ok, #state{metrics_set = sets:new()}}.


create_tables() ->
  [ets:new(T, [public, named_table, set, {keypos,#metric.name}]) || T <- tables()].

handle_call({reg, #metric{name=N}=Metric}, _From, #state{metrics_set = Set} = State) ->
  case ets:member(instrument_lib:table(), N) of
    true ->
      {reply, {error, already_exists}, State};
    false ->
      do_reg_metric(Metric),
      NewSet = sets:add_element(N, Set),
      sync_metrics_index(NewSet),
      {reply, ok, State#state{metrics_set = NewSet}}
  end;

handle_call({unreg, Name}, _From, #state{metrics_set = Set} = State) ->
  do_unreg_metric(Name),
  NewSet = sets:del_element(Name, Set),
  sync_metrics_index(NewSet),
  {reply, ok, State#state{metrics_set = NewSet}};

handle_call(unregister_all, _From, _State) ->
  do_delete_all(),
  _ = erlang:garbage_collect(self()),
  {reply, ok, #state{metrics_set = sets:new()}};


handle_call({create_vector_metric, Name, Label}, _From, State) ->
  Reply = case ets:lookup(instrument_lib:table(), Name) of
            [] -> ok;
            [Metric] ->
              Metric2 = do_create_metric(Metric, Label),
              do_reg_metric(Metric2),
              ok
          end,
  {reply, Reply, State};

handle_call({remove_label, Name, Label}, _From, State) ->
  Reply = case ets:lookup(instrument_lib:table(), Name) of
            [] -> ok;
            [Metric] ->
              Metric2 = do_remove_label(Metric, Label),
              do_reg_metric(Metric2),
              ok
          end,
  {reply, Reply, State};

handle_call({clear_labels, Name}, _From, State) ->
  Reply = case ets:lookup(instrument_lib:table(), Name) of
            [] -> ok;
            [Metric] ->
              Metric2 = do_clear_labels(Metric),
              do_reg_metric(Metric2),
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

%% @private Register a metric in ETS and persistent_term (for fast lookup).
%% Does NOT update the metrics index - that's handled by the gen_server state.
do_reg_metric(Metric) ->
  #metric{name = Name} = Metric,
  %% Store in ETS tables
  [ets:insert(T, Metric) || T <- tables()],
  %% Store in persistent_term for fast lookup
  persistent_term:put({instrument_metric, Name}, Metric).

%% @private Unregister a metric from ETS and persistent_term.
%% Does NOT update the metrics index - that's handled by the gen_server state.
do_unreg_metric(Name) ->
  %% Delete from all ETS tables (they're partitioned by scheduler)
  [ets:delete(T, Name) || T <- tables()],
  %% Remove from persistent_term
  catch persistent_term:erase({instrument_metric, Name}),
  %% Erase cached labels for this metric
  _ = erase_cached_labels(Name),
  ok.

%% @private Sync the metrics index from gen_server state to persistent_term.
%% This is the only place the instrument_metrics list is written.
sync_metrics_index(Set) ->
  persistent_term:put(instrument_metrics, sets:to_list(Set)).

erase_cached_labels(Name) ->
  Keys = persistent_term:get(),
  [persistent_term:erase(K) || {K, _} <- Keys,
   is_tuple(K), tuple_size(K) =:= 3,
   element(1, K) =:= instrument_label,
   element(2, K) =:= Name].

do_delete_all() ->
  [ets:delete_all_objects(T) || T <- instrument_lib:tables()],
  %% Clear all persistent_term entries
  Keys = persistent_term:get(),
  [persistent_term:erase(K) || {K, _} <- Keys,
   is_tuple(K), tuple_size(K) >= 2,
   element(1, K) =:= instrument_metric orelse
   element(1, K) =:= instrument_label],
  persistent_term:put(instrument_metrics, []).


tables() -> instrument_lib:tables().

%% persistent_term based lookup API

-spec lookup(term()) -> #metric{} | undefined.
lookup(Name) ->
  persistent_term:get({instrument_metric, Name}, undefined).

-spec lookup_label(term(), list()) -> #metric{} | undefined.
lookup_label(Name, LabelValues) ->
  persistent_term:get({instrument_label, Name, LabelValues}, undefined).

-spec cache_label(term(), list(), #metric{}) -> ok.
cache_label(Name, LabelValues, Metric) ->
  persistent_term:put({instrument_label, Name, LabelValues}, Metric).

-spec collect_all() -> [map()].
collect_all() ->
  Names = persistent_term:get(instrument_metrics, []),
  lists:filtermap(fun(Name) ->
    case lookup(Name) of
      undefined -> false;
      #metric{collect = {Mod, Fun, Args}} ->
        try
          {true, erlang:apply(Mod, Fun, Args)}
        catch
          Class:Reason:Stacktrace ->
            logger:warning("Metric collector ~p:~p failed: ~p:~p",
                          [Mod, Fun, Class, Reason],
                          #{error_logger => #{tag => warning_msg},
                            mfa => {Mod, Fun, length(Args)},
                            stacktrace => Stacktrace}),
            false
        end
    end
  end, Names).

%% Internal vector functions

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

do_remove_label(#metric{ name = Name, handle = Vector } = Metric, Label) ->
  #vector{ labels_map = LabelsMap } = Vector,
  %% Erase the cache entry for this specific label
  persistent_term:erase({instrument_label, Name, Label}),
  Vector2 = Vector#vector{labels_map=maps:remove(Label, LabelsMap)},
  Metric#metric{handle=Vector2}.

do_clear_labels(#metric{ name = Name, handle = Vector } = Metric) ->
  #vector{ labels_map = LabelsMap } = Vector,
  %% Erase cache entries for all labels
  maps:foreach(fun(LabelValues, _) ->
    persistent_term:erase({instrument_label, Name, LabelValues})
  end, LabelsMap),
  Vector2 = Vector#vector{labels_map=#{}},
  Metric#metric{handle=Vector2}.