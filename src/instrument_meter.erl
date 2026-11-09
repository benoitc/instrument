%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc OpenTelemetry-compatible MeterProvider and Meter API.
%%
%% This module provides an OTel-style API for creating and using metrics,
%% backed by the series store (instrument_series): one family per logical
%% metric name, attributes as label dimensions (never name material), no
%% phantom-zero series. A meter series exists iff it has been written.
%%
%% == Example Usage ==
%% ```
%% Meter = instrument_meter:get_meter(<<"my_service">>),
%% Counter = instrument_meter:create_counter(Meter, <<"requests_total">>, #{
%%   description => <<"Total requests">>,
%%   unit => <<"1">>
%% }),
%% instrument_meter:add(Counter, 1, #{method => <<"GET">>, status => 200}).
%% '''
-module(instrument_meter).
-author("benoitc").

%% MeterProvider API
-export([
  get_meter/1,
  get_meter/2,
  shutdown/0,
  force_flush/0
]).

%% Meter API - create instruments
-export([
  create_counter/2,
  create_counter/3,
  create_up_down_counter/2,
  create_up_down_counter/3,
  create_histogram/2,
  create_histogram/3,
  create_gauge/2,
  create_gauge/3,
  create_observable_counter/3,
  create_observable_gauge/3,
  create_observable_up_down_counter/3
]).

%% Operations
-export([
  add/2,
  add/3,
  record/2,
  record/3,
  set/2,
  set/3
]).

%% Callbacks registered for several observable instruments
-export([
  register_callback/2,
  unregister_callback/1
]).

%% Utility
-export([
  get_instrument/1,
  list_instruments/0,
  collect_observables/0,
  unregister_instrument/1,
  unregister_all_instruments/0
]).

%% Internal: callback table lifecycle, driven by instrument_registry
-export([
  init_callback_table/0,
  clear_callbacks/0
]).

-include("instrument.hrl").
-include("instrument_otel.hrl").

-define(CALLBACKS, instrument_observable_callbacks).

-type meter() :: #meter{}.
-type instrument() :: #otel_instrument{}.
-type instrument_opts() :: #{
  description => binary(),
  unit => binary(),
  boundaries => [number()],  %% for histograms
  temporality => cumulative | delta  %% aggregation temporality (default: cumulative)
}.

-type observe_fun() :: fun((instrument() | binary() | atom(), number(), map()) -> ok | {error, term()}).

-export_type([meter/0, instrument/0, instrument_opts/0, observe_fun/0]).

%% ============================================================================
%% MeterProvider API
%% ============================================================================

%% @doc Gets or creates a Meter with the given name.
-spec get_meter(binary() | atom()) -> meter().
get_meter(Name) ->
  get_meter(Name, #{}).

%% @doc Gets or creates a Meter with the given name and options.
-spec get_meter(binary() | atom(), map()) -> meter().
get_meter(Name, Opts) when is_atom(Name) ->
  get_meter(atom_to_binary(Name, utf8), Opts);
get_meter(Name, Opts) when is_binary(Name), is_map(Opts) ->
  Version = maps:get(version, Opts, undefined),
  SchemaUrl = maps:get(schema_url, Opts, undefined),
  Resource = maps:get(resource, Opts, undefined),
  #meter{
    name = Name,
    version = Version,
    schema_url = SchemaUrl,
    resource = Resource
  }.

%% @doc Shuts down the MeterProvider.
%% This is a no-op in the current implementation.
-spec shutdown() -> ok.
shutdown() ->
  ok.

%% @doc Forces a flush of all pending metrics.
%% This is a no-op in the current implementation.
-spec force_flush() -> ok.
force_flush() ->
  ok.

%% ============================================================================
%% Meter API - Create Instruments
%% ============================================================================

%% @doc Creates a Counter instrument.
-spec create_counter(meter(), binary() | atom()) -> instrument().
create_counter(Meter, Name) ->
  create_counter(Meter, Name, #{}).

%% @doc Creates a Counter instrument with options.
-spec create_counter(meter(), binary() | atom(), instrument_opts()) -> instrument().
create_counter(Meter, Name, Opts) ->
  create_instrument(Meter, Name, counter, Opts).

%% @doc Creates an UpDownCounter instrument.
-spec create_up_down_counter(meter(), binary() | atom()) -> instrument().
create_up_down_counter(Meter, Name) ->
  create_up_down_counter(Meter, Name, #{}).

%% @doc Creates an UpDownCounter instrument with options.
-spec create_up_down_counter(meter(), binary() | atom(), instrument_opts()) -> instrument().
create_up_down_counter(Meter, Name, Opts) ->
  create_instrument(Meter, Name, up_down_counter, Opts).

%% @doc Creates a Histogram instrument.
-spec create_histogram(meter(), binary() | atom()) -> instrument().
create_histogram(Meter, Name) ->
  create_histogram(Meter, Name, #{}).

%% @doc Creates a Histogram instrument with options.
-spec create_histogram(meter(), binary() | atom(), instrument_opts()) -> instrument().
create_histogram(Meter, Name, Opts) ->
  create_instrument(Meter, Name, histogram, Opts).

%% @doc Creates a Gauge instrument.
-spec create_gauge(meter(), binary() | atom()) -> instrument().
create_gauge(Meter, Name) ->
  create_gauge(Meter, Name, #{}).

%% @doc Creates a Gauge instrument with options.
-spec create_gauge(meter(), binary() | atom(), instrument_opts()) -> instrument().
create_gauge(Meter, Name, Opts) ->
  create_instrument(Meter, Name, gauge, Opts).

%% @doc Creates an ObservableCounter.
%% The third argument is either a callback or an options map:
%% - 0-arity fun: fun() -> number() - returns a single value
%% - 1-arity fun: fun(Observe) -> ok - calls Observe(Value, Attrs) for each observation
%% - map (description, unit): no callback of its own; feed it from a callback
%%   passed to register_callback/2
-spec create_observable_counter(meter(), binary() | atom(), fun() | instrument_opts()) -> instrument().
create_observable_counter(Meter, Name, Callback) when is_function(Callback) ->
  create_observable_instrument(Meter, Name, observable_counter, Callback, #{});
create_observable_counter(Meter, Name, Opts) when is_map(Opts) ->
  create_observable_instrument(Meter, Name, observable_counter, undefined, Opts).

%% @doc Creates an ObservableGauge.
%% The third argument is either a callback or an options map:
%% - 0-arity fun: fun() -> number() - returns a single value
%% - 1-arity fun: fun(Observe) -> ok - calls Observe(Value, Attrs) for each observation
%% - map (description, unit): no callback of its own; feed it from a callback
%%   passed to register_callback/2
-spec create_observable_gauge(meter(), binary() | atom(), fun() | instrument_opts()) -> instrument().
create_observable_gauge(Meter, Name, Callback) when is_function(Callback) ->
  create_observable_instrument(Meter, Name, observable_gauge, Callback, #{});
create_observable_gauge(Meter, Name, Opts) when is_map(Opts) ->
  create_observable_instrument(Meter, Name, observable_gauge, undefined, Opts).

%% @doc Creates an ObservableUpDownCounter.
%% The third argument is either a callback or an options map:
%% - 0-arity fun: fun() -> number() - returns a single value
%% - 1-arity fun: fun(Observe) -> ok - calls Observe(Value, Attrs) for each observation
%% - map (description, unit): no callback of its own; feed it from a callback
%%   passed to register_callback/2
-spec create_observable_up_down_counter(meter(), binary() | atom(), fun() | instrument_opts()) -> instrument().
create_observable_up_down_counter(Meter, Name, Callback) when is_function(Callback) ->
  create_observable_instrument(Meter, Name, observable_up_down_counter, Callback, #{});
create_observable_up_down_counter(Meter, Name, Opts) when is_map(Opts) ->
  create_observable_instrument(Meter, Name, observable_up_down_counter, undefined, Opts).

%% ============================================================================
%% Operations
%% ============================================================================

%% @doc Adds a value to a Counter or UpDownCounter.
-spec add(instrument(), number()) -> ok.
add(Instrument, Value) ->
  add(Instrument, Value, #{}).

%% @doc Adds a value to a Counter or UpDownCounter with attributes.
-spec add(instrument(), number(), map()) -> any().
%% Unlabeled fast path (no attrs): bare kind/value, no per-call closures.
add(#otel_instrument{kind = counter} = I, Value, Attrs)
    when is_number(Value), Value >= 0, map_size(Attrs) =:= 0 ->
  unlabeled(I, counter, Value);
add(#otel_instrument{kind = up_down_counter} = I, Value, Attrs)
    when is_number(Value), map_size(Attrs) =:= 0 ->
  unlabeled(I, up_down_counter, Value);
%% Labeled path (unchanged behavior; map_size guard made explicit).
add(#otel_instrument{kind = counter, handle = RegName}, Value, Attrs)
    when is_number(Value), Value >= 0, map_size(Attrs) > 0 ->
  do_write(RegName, Attrs, fun(R) -> instrument_counter:inc_counter(R, Value) end);
add(#otel_instrument{kind = up_down_counter, handle = RegName}, Value, Attrs)
    when is_number(Value), Value >= 0, map_size(Attrs) > 0 ->
  do_write(RegName, Attrs, fun(R) -> instrument_gauge:inc_gauge(R, Value) end);
add(#otel_instrument{kind = up_down_counter, handle = RegName}, Value, Attrs)
    when is_number(Value), Value < 0, map_size(Attrs) > 0 ->
  do_write(RegName, Attrs, fun(R) -> instrument_gauge:dec_gauge(R, -Value) end);
add(_, _, _) ->
  {error, invalid_operation}.

%% Unlabeled write through the cell held by the instrument. A slot that is not
%% live (never written, cleared, or the metric was removed) goes through the
%% series store, which creates or revives the series, or reaches a metric
%% re-created under the same name.
unlabeled(#otel_instrument{unlabeled = {Epochs, Cell}, handle = RegName}, Kind, Value) ->
  case atomics:get(Epochs, 1) band 1 of
    1 -> write_cell(Kind, Cell, Value);
    0 -> instrument_series:write_unlabeled(RegName, Kind, Value)
  end;
unlabeled(#otel_instrument{handle = RegName}, Kind, Value) ->
  instrument_series:write_unlabeled(RegName, Kind, Value).

write_cell(counter, Cell, V)                     -> instrument_counter:inc_counter(Cell, V);
write_cell(up_down_counter, Cell, V) when V >= 0 -> instrument_gauge:inc_gauge(Cell, V);
write_cell(up_down_counter, Cell, V)             -> instrument_gauge:dec_gauge(Cell, -V);
write_cell(gauge, Cell, V)                       -> instrument_gauge:set_gauge(Cell, V);
write_cell(histogram, Cell, V)                   -> instrument_histogram:observe_histogram(Cell, V).

%% @doc Records a value in a Histogram.
-spec record(instrument(), number()) -> ok.
record(Instrument, Value) ->
  record(Instrument, Value, #{}).

%% @doc Records a value in a Histogram with attributes.
-spec record(instrument(), number(), map()) -> any().
record(#otel_instrument{kind = histogram} = I, Value, Attrs)
    when is_number(Value), map_size(Attrs) =:= 0 ->
  unlabeled(I, histogram, Value);
record(#otel_instrument{kind = histogram, handle = RegName}, Value, Attrs)
    when is_number(Value), map_size(Attrs) > 0 ->
  do_write(RegName, Attrs, fun(R) -> instrument_histogram:observe_histogram(R, Value) end);
record(_, _, _) ->
  {error, invalid_operation}.

%% @doc Sets a value on a Gauge.
-spec set(instrument(), number()) -> ok.
set(Instrument, Value) ->
  set(Instrument, Value, #{}).

%% @doc Sets a value on a Gauge with attributes.
-spec set(instrument(), number(), map()) -> any().
set(#otel_instrument{kind = gauge} = I, Value, Attrs)
    when is_number(Value), map_size(Attrs) =:= 0 ->
  unlabeled(I, gauge, Value);
set(#otel_instrument{kind = gauge, handle = RegName}, Value, Attrs)
    when is_number(Value), map_size(Attrs) > 0 ->
  do_write(RegName, Attrs, fun(R) -> instrument_gauge:set_gauge(R, Value) end);
set(_, _, _) ->
  {error, invalid_operation}.

%% ============================================================================
%% Utility
%% ============================================================================

%% @doc Gets an instrument by name.
-spec get_instrument(binary() | atom()) -> instrument() | undefined.
get_instrument(Name) when is_atom(Name) ->
  get_instrument(atom_to_binary(Name, utf8));
get_instrument(Name) when is_binary(Name) ->
  Key = {otel_instrument, Name},
  persistent_term:get(Key, undefined).

%% @doc Lists all registered instruments.
%% Walks the series-store family chain and resolves the meter descriptor for
%% every {otel, _} family name. The chain is the single source of truth — the
%% old per-create `otel_instruments` pt list (and its sweep) is gone.
-spec list_instruments() -> [instrument()].
list_instruments() ->
  case persistent_term:get(instrument_family_seq, undefined) of
    undefined -> [];
    FamSeq ->
      N = atomics:get(FamSeq, 1),
      lists:filtermap(fun(K) ->
        case persistent_term:get({instrument_family_idx, K}, undefined) of
          {otel, Name} -> resolve_instrument(Name);
          _ -> false
        end
      end, lists:seq(1, N))
  end.

resolve_instrument(Name) ->
  case get_instrument(Name) of
    undefined -> false;
    Inst -> {true, Inst}
  end.

%% @doc Invokes all observable instrument callbacks.
%% This should be called before metrics collection to update observable values.
%% Runs each instrument's own callback, then each callback registered with
%% register_callback/2, once per call.
-spec collect_observables() -> ok.
collect_observables() ->
  lists:foreach(fun collect_observable/1, list_instruments()),
  lists:foreach(fun run_registered_callback/1, registered_callbacks()),
  ok.

collect_observable(#otel_instrument{kind = Kind,
                                    handle = {observable, RegName, Callback}})
    when is_function(Callback),
         (Kind =:= observable_counter orelse
          Kind =:= observable_gauge orelse
          Kind =:= observable_up_down_counter) ->
  try
    case erlang:fun_info(Callback, arity) of
      {arity, 0} ->
        %% Legacy 0-arity callback — returns a single absolute value.
        observe(RegName, Callback(), #{});
      {arity, 1} ->
        %% Observer-pattern callback — observes (Value, Attrs) tuples; each is
        %% an ordinary labeled write under the real instrument name.
        Callback(fun(Value, ObsAttrs) -> observe(RegName, Value, ObsAttrs) end)
    end
  catch
    _:_ -> ok
  end;
collect_observable(_) ->
  ok.

%% One observation into an observable instrument's series.
observe(RegName, Value, Attrs) when is_number(Value), is_map(Attrs) ->
  do_write(RegName, Attrs, set_fun(Value));
observe(_RegName, _Value, _Attrs) ->
  {error, invalid_observation}.

%% ============================================================================
%% Callbacks registered for several observable instruments
%% ============================================================================

%% @doc Registers one callback that observes several observable instruments.
%% The callback runs once per collection and receives an Observe function:
%% Observe(Instrument, Value, Attrs) records Value for Instrument, which may be
%% given as the instrument record or its name. Observations for instruments
%% not passed here, or no longer registered, are ignored. Use it when several
%% instruments derive from one expensive source: fetch it once in the callback
%% and observe every instrument from the result.
-spec register_callback([instrument()], fun((observe_fun()) -> term())) ->
  {ok, reference()} | {error, term()}.
register_callback([], _Callback) ->
  {error, no_instruments};
register_callback(Instruments, Callback)
    when is_list(Instruments), is_function(Callback, 1) ->
  case callback_names(Instruments, []) of
    {ok, Names} ->
      Ref = make_ref(),
      true = ets:insert(?CALLBACKS, {Ref, Names, Callback}),
      {ok, Ref};
    {error, _} = Error ->
      Error
  end;
register_callback(_Instruments, _Callback) ->
  {error, badarg}.

%% @doc Removes a callback registered with register_callback/2.
-spec unregister_callback(reference()) -> ok.
unregister_callback(Ref) when is_reference(Ref) ->
  _ = instrument_lib:safe_apply(ets, delete, [?CALLBACKS, Ref], true),
  ok.

callback_names([#otel_instrument{name = Name, kind = Kind} | Rest], Acc)
    when Kind =:= observable_counter;
         Kind =:= observable_gauge;
         Kind =:= observable_up_down_counter ->
  callback_names(Rest, [Name | Acc]);
callback_names([#otel_instrument{name = Name} | _], _Acc) ->
  {error, {not_observable, Name}};
callback_names([Other | _], _Acc) ->
  {error, {not_an_instrument, Other}};
callback_names([], Acc) ->
  {ok, lists:usort(Acc)}.

registered_callbacks() ->
  instrument_lib:safe_call(fun() -> ets:tab2list(?CALLBACKS) end, []).

run_registered_callback({_Ref, Names, Callback}) ->
  Observe = fun(Target, Value, Attrs) ->
    observe_registered(Names, target_name(Target), Value, Attrs)
  end,
  try Callback(Observe) catch _:_ -> ok end.

observe_registered(_Names, undefined, _Value, _Attrs) ->
  {error, unknown_instrument};
observe_registered(Names, Name, Value, Attrs) ->
  case lists:member(Name, Names) andalso get_instrument(Name) of
    #otel_instrument{handle = {observable, RegName, _}} ->
      observe(RegName, Value, Attrs);
    _ ->
      {error, unknown_instrument}
  end.

target_name(#otel_instrument{name = Name}) -> Name;
target_name(Name) when is_binary(Name) -> Name;
target_name(Name) when is_atom(Name) -> atom_to_binary(Name, utf8);
target_name(_) -> undefined.

%% @private Created by instrument_registry:init/1 so the table lives as long
%% as the registry.
-spec init_callback_table() -> ok.
init_callback_table() ->
  case ets:info(?CALLBACKS, name) of
    undefined ->
      _ = ets:new(?CALLBACKS, [set, public, named_table, {read_concurrency, true}]),
      ok;
    _ ->
      ok
  end.

%% @private Drops every registered callback (registry unregister_all).
-spec clear_callbacks() -> ok.
clear_callbacks() ->
  _ = instrument_lib:safe_apply(ets, delete_all_objects, [?CALLBACKS], true),
  ok.

%% Observable callbacks report absolute values (set-semantics) into gauge-shaped
%% rows; observable_counter wire-type rendering is driven by the family kind.
set_fun(Value) ->
  fun(R) -> instrument_gauge:set_gauge(R, float(Value)) end.

%% @doc Unregisters an instrument by name.
%% Registry unregister runs the full series-store family teardown (chain walk,
%% cache keys, reservoirs, counters); we additionally erase the meter descriptor.
-spec unregister_instrument(binary() | atom()) -> ok | {error, not_found}.
unregister_instrument(Name) when is_atom(Name) ->
  unregister_instrument(atom_to_binary(Name, utf8));
unregister_instrument(Name) when is_binary(Name) ->
  Key = {otel_instrument, Name},
  case persistent_term:get(Key, undefined) of
    undefined ->
      {error, not_found};
    #otel_instrument{} ->
      %% Harmless legacy cleanup (the {otel, Name} legacy structures, if any).
      _ = instrument_registry:unregister({otel, Name}),
      _ = persistent_term:erase(Key),
      ok
  end.

%% @doc Unregisters all OTel instruments.
-spec unregister_all_instruments() -> ok.
unregister_all_instruments() ->
  lists:foreach(fun(#otel_instrument{name = Name}) ->
    _ = unregister_instrument(Name)
  end, list_instruments()),
  ok.

%% ============================================================================
%% Internal Functions
%% ============================================================================

create_instrument(#meter{} = Meter, Name, Kind, Opts) when is_atom(Name) ->
  create_instrument(Meter, atom_to_binary(Name, utf8), Kind, Opts);
create_instrument(#meter{} = Meter, Name, Kind, Opts) when is_binary(Name), is_map(Opts) ->
  Description = maps:get(description, Opts, undefined),
  Unit = maps:get(unit, Opts, undefined),
  Temporality = maps:get(temporality, Opts, cumulative),

  %% Check if already exists (idempotent create, master parity).
  case get_instrument(Name) of
    undefined ->
      RegName = {otel, Name},
      #family{chunk0 = {Epochs, Rows}} = register_family(RegName, Kind, Description, Opts),
      Instrument = #otel_instrument{
        name = Name,
        kind = Kind,
        description = Description,
        unit = Unit,
        meter = Meter,
        handle = RegName,
        temporality = Temporality,
        %% slot 1 always holds the unlabeled series and is never reused
        unlabeled = {Epochs, element(1, Rows)}
      },
      persistent_term:put({otel_instrument, Name}, Instrument),
      Instrument;
    Existing ->
      Existing
  end.

create_observable_instrument(#meter{} = Meter, Name, Kind, Callback, Opts) when is_atom(Name) ->
  create_observable_instrument(Meter, atom_to_binary(Name, utf8), Kind, Callback, Opts);
create_observable_instrument(#meter{} = Meter, Name, Kind, Callback, Opts) when is_binary(Name) ->
  %% Validate callback arity (0 or 1); undefined means no callback of its own.
  case Callback of
    undefined -> ok;
    _ ->
      case erlang:fun_info(Callback, arity) of
        {arity, 0} -> ok;
        {arity, 1} -> ok;
        Arity -> error({invalid_callback_arity, Arity})
      end
  end,
  case get_instrument(Name) of
    undefined ->
      RegName = {otel, Name},
      Description = maps:get(description, Opts, undefined),
      register_family(RegName, Kind, Description, Opts),
      Instrument = #otel_instrument{
        name = Name,
        kind = Kind,
        description = Description,
        unit = maps:get(unit, Opts, undefined),
        meter = Meter,
        handle = {observable, RegName, Callback}
      },
      persistent_term:put({otel_instrument, Name}, Instrument),
      Instrument;
    Existing ->
      Existing
  end.

%% Register the series-store family for an instrument. Boundaries are resolved
%% for histograms only (view → opts → OTel defaults); other kinds pass
%% undefined. Meter families are schema-free (declared_labels = undefined).
register_family(RegName, Kind, Description, Opts) ->
  Help = case Description of
    undefined -> <<>>;
    _ -> Description
  end,
  Boundaries = family_boundaries(RegName, Kind, Opts),
  instrument_series:ensure_family(RegName, Kind, Help, undefined, Boundaries).

family_boundaries({otel, Name}, histogram, Opts) ->
  Boundaries = case find_view_boundaries(Name) of
    undefined -> maps:get(boundaries, Opts, default_boundaries());
    B -> B
  end,
  %% Fail at creation rather than on every record/2 call.
  ok = instrument_histogram:validate_buckets(Boundaries),
  Boundaries;
family_boundaries(_RegName, _Kind, _Opts) ->
  undefined.

%% The unified write path: all add/record/set funnel here. Attrs canonicalize
%% to {SortedNames, Values}; that canon is also the cache key (the meter sorts
%% attrs anyway, so the hot path does zero extra work). {} -> {[], []}.
do_write(RegName, Attrs, WriteFun) ->
  Canon = attrs_to_labels(Attrs),
  instrument_series:write(RegName, Canon, fun() -> Canon end, WriteFun).

default_boundaries() ->
  %% Default histogram boundaries per OTel spec
  [0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1.0, 2.5, 5.0, 7.5, 10.0].

%% @doc Convert attribute map to sorted label names and values.
%% #{method =&gt; &lt;&lt;"GET"&gt;&gt;, status =&gt; 200} -&gt; {[method, status], [&lt;&lt;"GET"&gt;&gt;, &lt;&lt;"200"&gt;&gt;]}
attrs_to_labels(Attrs) ->
  Sorted = lists:sort(maps:to_list(Attrs)),
  {[K || {K, _} <- Sorted],
   [instrument_series:to_label_value(V) || {_, V} <- Sorted]}.

%% Find histogram boundaries from registered views
find_view_boundaries(Name) ->
  Views = instrument_metric_view:list(),
  %% Find first matching view with boundaries defined
  case [V || #metric_view{instrument_name = N, boundaries = B} = V <- Views,
             (N =:= Name orelse N =:= '_'), B =/= undefined] of
    [#metric_view{boundaries = B} | _] -> B;
    [] -> undefined
  end.
