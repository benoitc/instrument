%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Metrics exporter manager for periodic metrics collection and export.
%%
%% This module manages metrics exporters and handles periodic collection
%% and export of metrics to registered backends.
%%
%% == Example Usage ==
%% ```
%% %% Register console exporter for metrics
%% instrument_metrics_exporter:register(instrument_metrics_exporter_console:new()),
%%
%% %% Register OTLP exporter
%% instrument_metrics_exporter:register(instrument_metrics_exporter_otlp:new(#{
%%     endpoint => "http://localhost:4318"
%% })),
%%
%% %% Metrics are collected and exported periodically
%% '''
-module(instrument_metrics_exporter).
-author("benoitc").

-behaviour(gen_server).

%% API
-export([
  start_link/0,
  register/1,
  unregister/1,
  list/0,
  collect/0,
  export/0,
  flush/0,
  shutdown/0,
  decumulative_counts/1
]).

%% Exporter behaviour callbacks
-export([
  behaviour_info/1
]).

%% gen_server callbacks
-export([
  init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3
]).

-include("instrument.hrl").
-include("instrument_otel.hrl").

-record(state, {
  exporters = [] :: [exporter()],
  interval = 60000 :: pos_integer(),  %% Export interval in ms (default 60s)
  timer_ref :: reference() | undefined
}).

-type exporter() :: #{
  module := module(),
  config := map(),
  state := term()
}.

-type metric_data() :: #{
  name := binary(),
  description := binary(),
  unit := binary(),
  type := counter | gauge | histogram,
  data_points := [data_point()]
}.

-type data_point() :: #{
  attributes := map(),
  value := number() | histogram_value(),
  timestamp := integer()
}.

-type histogram_value() :: #{
  count := integer(),
  sum := number(),
  buckets := [#{bound := number(), count := integer()}]
}.

-export_type([exporter/0, metric_data/0, data_point/0]).

%% @doc Behaviour callbacks for metrics exporters
behaviour_info(callbacks) ->
  [
    {exporter_init, 1},        %% exporter_init(Config) -> {ok, State} | {error, Reason}
    {exporter_export, 2},      %% exporter_export(Metrics, State) -> {ok, NewState} | {error, Reason, NewState}
    {exporter_shutdown, 1}     %% exporter_shutdown(State) -> ok
  ];
behaviour_info(_) ->
  undefined.

%% ============================================================================
%% API
%% ============================================================================

%% @doc Starts the metrics exporter manager.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Registers a metrics exporter.
-spec register(#{module := module(), config => map()}) -> ok | {error, term()}.
register(#{module := Module} = Exporter) ->
  Config = maps:get(config, Exporter, #{}),
  gen_server:call(?MODULE, {register, Module, Config}).

%% @doc Unregisters a metrics exporter.
-spec unregister(module()) -> ok.
unregister(Module) ->
  gen_server:call(?MODULE, {unregister, Module}).

%% @doc Lists all registered exporters.
-spec list() -> [module()].
list() ->
  gen_server:call(?MODULE, list).

%% @doc Collects all metrics.
-spec collect() -> [metric_data()].
collect() ->
  collect_metrics().

%% @doc Triggers an immediate export.
-spec export() -> ok.
export() ->
  gen_server:cast(?MODULE, export).

%% @doc Forces a flush of metrics to all exporters.
-spec flush() -> ok.
flush() ->
  gen_server:call(?MODULE, flush, 30000).

%% @doc Shuts down all exporters.
-spec shutdown() -> ok.
shutdown() ->
  gen_server:call(?MODULE, shutdown, 30000).

%% ============================================================================
%% gen_server callbacks
%% ============================================================================

init([]) ->
  Interval = application:get_env(instrument, metrics_export_interval, 60000),
  State = #state{interval = Interval},
  {ok, schedule_export(State)}.

handle_call({register, Module, Config}, _From, State) ->
  case Module:exporter_init(Config) of
    {ok, ExporterState} ->
      Exporter = #{module => Module, config => Config, state => ExporterState},
      NewExporters = [Exporter | State#state.exporters],
      {reply, ok, State#state{exporters = NewExporters}};
    {error, Reason} ->
      {reply, {error, Reason}, State}
  end;

handle_call({unregister, Module}, _From, State) ->
  {Removed, Remaining} = lists:partition(
    fun(#{module := M}) -> M =:= Module end,
    State#state.exporters
  ),
  lists:foreach(fun(#{module := M, state := S}) ->
    instrument_lib:safe_apply(M, exporter_shutdown, [S], ok)
  end, Removed),
  {reply, ok, State#state{exporters = Remaining}};

handle_call(list, _From, State) ->
  Modules = [M || #{module := M} <- State#state.exporters],
  {reply, Modules, State};

handle_call(flush, _From, State) ->
  State2 = do_export(State),
  {reply, ok, State2};

handle_call(shutdown, _From, State) ->
  State2 = do_export(State),
  lists:foreach(fun(#{module := M, state := S}) ->
    instrument_lib:safe_apply(M, exporter_shutdown, [S], ok)
  end, State2#state.exporters),
  cancel_timer(State2),
  {reply, ok, State2#state{exporters = []}};

handle_call(_Request, _From, State) ->
  {reply, {error, unknown_request}, State}.

handle_cast(export, State) ->
  State2 = do_export(State),
  {noreply, State2};

handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info(export_metrics, State) ->
  State2 = do_export(State#state{timer_ref = undefined}),
  {noreply, schedule_export(State2)};

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, State) ->
  do_export(State),
  lists:foreach(fun(#{module := M, state := S}) ->
    instrument_lib:safe_apply(M, exporter_shutdown, [S], ok)
  end, State#state.exporters),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% ============================================================================
%% Internal functions
%% ============================================================================

schedule_export(#state{interval = Interval} = State) ->
  Ref = erlang:send_after(Interval, self(), export_metrics),
  State#state{timer_ref = Ref}.

cancel_timer(#state{timer_ref = undefined}) ->
  ok;
cancel_timer(#state{timer_ref = Ref}) ->
  erlang:cancel_timer(Ref),
  ok.

do_export(#state{exporters = []} = State) ->
  State;
do_export(#state{exporters = Exporters} = State) ->
  Metrics = collect_metrics(),
  %% Apply metric views for transformation
  TransformedMetrics = instrument_metric_view:apply_views(Metrics),
  NewExporters = lists:map(fun(#{module := M, state := S} = Exporter) ->
    %% Check if exporter is enabled at runtime
    case instrument_config:is_exporter_enabled(M) of
      false ->
        %% Skip disabled exporter
        Exporter;
      true ->
        try M:exporter_export(TransformedMetrics, S) of
          {ok, NewState} ->
            Exporter#{state => NewState};
          {error, _Reason, NewState} ->
            Exporter#{state => NewState};
          _ ->
            Exporter
        catch _:_ ->
          Exporter
        end
    end
  end, Exporters),
  State#state{exporters = NewExporters}.

collect_metrics() ->
  %% First, invoke all observable callbacks to update their values
  instrument_meter:collect_observables(),
  RawMetrics = instrument_registry:collect_all(),
  Timestamp = erlang:system_time(nanosecond),
  lists:filtermap(fun(Metric) ->
    case convert_metric(Metric, Timestamp) of
      undefined -> false;
      Converted -> {true, Converted}
    end
  end, RawMetrics).

convert_metric(#{type := counter, name := Name, help := Help, val := Val} = Metric, Timestamp) ->
  StartTime = maps:get(start_time, Metric, undefined),
  #{
    name => to_binary(Name),
    description => extract_help(Help),
    unit => get_instrument_unit(Name),
    type => counter,
    data_points => [#{
      attributes => #{},
      value => Val,
      timestamp => Timestamp,
      start_time => StartTime
    }]
  };

convert_metric(#{type := counter, name := Name, help := Help, labels := Labels, data := Data}, Timestamp) ->
  #{
    name => to_binary(Name),
    description => extract_help(Help),
    unit => get_instrument_unit(Name),
    type => counter,
    data_points => [#{
      attributes => make_attributes(Labels, LabelVals),
      value => Val,
      timestamp => Timestamp
    } || {_, LabelVals, Val} <- Data]
  };

convert_metric(#{type := gauge, name := Name, help := Help, val := Val}, Timestamp) ->
  #{
    name => to_binary(Name),
    description => extract_help(Help),
    unit => get_instrument_unit(Name),
    type => gauge,
    data_points => [#{
      attributes => #{},
      value => Val,
      timestamp => Timestamp
    }]
  };

convert_metric(#{type := gauge, name := Name, help := Help, labels := Labels, data := Data}, Timestamp) ->
  #{
    name => to_binary(Name),
    description => extract_help(Help),
    unit => get_instrument_unit(Name),
    type => gauge,
    data_points => [#{
      attributes => make_attributes(Labels, LabelVals),
      value => Val,
      timestamp => Timestamp
    } || {_, LabelVals, Val} <- Data]
  };

convert_metric(#{type := histogram, name := Name, help := Help, count := Count, sum := Sum, buckets := Buckets} = Metric, Timestamp) ->
  StartTime = maps:get(start_time, Metric, undefined),
  #{
    name => to_binary(Name),
    description => extract_help(Help),
    unit => get_instrument_unit(Name),
    type => histogram,
    data_points => [#{
      attributes => #{},
      value => #{
        count => Count,
        sum => Sum,
        buckets => [#{bound => maps:get(upper_bound, B), count => maps:get(cumulative_count, B)} || B <- Buckets]
      },
      timestamp => Timestamp,
      start_time => StartTime
    }]
  };

convert_metric(#{type := histogram, name := Name, help := Help, labels := Labels, data := Data}, Timestamp) ->
  #{
    name => to_binary(Name),
    description => extract_help(Help),
    unit => get_instrument_unit(Name),
    type => histogram,
    data_points => [#{
      attributes => make_attributes(Labels, LabelVals),
      value => #{
        count => maps:get(count, Val),
        sum => maps:get(sum, Val),
        buckets => [#{bound => maps:get(upper_bound, B), count => maps:get(cumulative_count, B)}
                    || B <- maps:get(buckets, Val)]
      },
      timestamp => Timestamp
    } || {_, LabelVals, Val} <- Data]
  };

convert_metric(_, _) ->
  undefined.

%% @doc Convert cumulative bucket counts to per-bucket counts for OTLP-style
%% output. Buckets are in ascending bound order with the +Inf bucket last, and
%% each `count' is the cumulative count up to and including that bound; OTLP
%% `bucketCounts' want the per-bucket delta. The Prometheus/console-text paths
%% keep using the cumulative form, so this is only for the JSON encoders.
-spec decumulative_counts([#{count => number(), _ => _}]) -> [number()].
decumulative_counts(Buckets) ->
  {Counts, _Last} =
    lists:mapfoldl(fun(B, Prev) ->
      Cum = maps:get(count, B, 0),
      {Cum - Prev, Cum}
    end, 0, Buckets),
  Counts.

%% Extract help text from proplist or return as-is if already a string/binary
extract_help(Help) when is_list(Help) ->
  case proplists:get_value(help, Help) of
    undefined -> to_binary(Help);
    HelpText -> to_binary(HelpText)
  end;
extract_help(Help) ->
  to_binary(Help).

make_attributes(Labels, LabelVals) ->
  lists:foldl(fun({Label, Val}, Acc) ->
    maps:put(to_binary(Label), to_binary(Val), Acc)
  end, #{}, lists:zip(Labels, LabelVals)).

%% Get unit from otel_instrument if available, otherwise default to "1"
get_instrument_unit({otel, Name}) when is_binary(Name) ->
  get_instrument_unit(Name);
get_instrument_unit({otel_vec, Name}) when is_binary(Name) ->
  %% For vec metrics, strip the label suffix to get base name
  get_instrument_unit(Name);
get_instrument_unit(Name) when is_binary(Name) ->
  case instrument_meter:get_instrument(Name) of
    #otel_instrument{unit = Unit} when Unit =/= undefined -> Unit;
    _ -> <<"1">>
  end;
get_instrument_unit(_) ->
  <<"1">>.

to_binary({otel, Name}) when is_binary(Name) -> Name;
to_binary({otel_vec, Name}) when is_binary(Name) -> Name;
to_binary(V) when is_binary(V) -> V;
to_binary(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_binary(V) when is_list(V) -> list_to_binary(V);
to_binary(V) when is_integer(V) -> integer_to_binary(V);
to_binary(V) -> iolist_to_binary(io_lib:format("~p", [V])).
