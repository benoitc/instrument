%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc OpenTelemetry-compatible MeterProvider and Meter API.
%%
%% This module provides an OTel-style API for creating and using metrics,
%% backed by the existing NIF infrastructure.
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

%% Utility
-export([
  get_instrument/1,
  list_instruments/0,
  collect_observables/0,
  unregister_instrument/1,
  unregister_all_instruments/0
]).

-include("instrument.hrl").
-include("instrument_otel.hrl").

-type meter() :: #meter{}.
-type instrument() :: #otel_instrument{}.
-type instrument_opts() :: #{
  description => binary(),
  unit => binary(),
  boundaries => [number()]  %% for histograms
}.

-export_type([meter/0, instrument/0, instrument_opts/0]).

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

%% @doc Creates an ObservableCounter with a callback.
-spec create_observable_counter(meter(), binary() | atom(), fun(() -> number())) -> instrument().
create_observable_counter(Meter, Name, Callback) when is_function(Callback, 0) ->
  create_observable_instrument(Meter, Name, observable_counter, Callback).

%% @doc Creates an ObservableGauge with a callback.
-spec create_observable_gauge(meter(), binary() | atom(), fun(() -> number())) -> instrument().
create_observable_gauge(Meter, Name, Callback) when is_function(Callback, 0) ->
  create_observable_instrument(Meter, Name, observable_gauge, Callback).

%% @doc Creates an ObservableUpDownCounter with a callback.
-spec create_observable_up_down_counter(meter(), binary() | atom(), fun(() -> number())) -> instrument().
create_observable_up_down_counter(Meter, Name, Callback) when is_function(Callback, 0) ->
  create_observable_instrument(Meter, Name, observable_up_down_counter, Callback).

%% ============================================================================
%% Operations
%% ============================================================================

%% @doc Adds a value to a Counter or UpDownCounter.
-spec add(instrument(), number()) -> ok.
add(Instrument, Value) ->
  add(Instrument, Value, #{}).

%% @doc Adds a value to a Counter or UpDownCounter with attributes.
-spec add(instrument(), number(), map()) -> ok.
add(#otel_instrument{kind = counter, handle = Handle}, Value, Attrs) when Value >= 0 ->
  do_add(Handle, Value, Attrs);
add(#otel_instrument{kind = up_down_counter, handle = Handle}, Value, Attrs) ->
  do_add(Handle, Value, Attrs);
add(_, _, _) ->
  {error, invalid_operation}.

%% @doc Records a value in a Histogram.
-spec record(instrument(), number()) -> ok.
record(Instrument, Value) ->
  record(Instrument, Value, #{}).

%% @doc Records a value in a Histogram with attributes.
-spec record(instrument(), number(), map()) -> ok.
record(#otel_instrument{kind = histogram, handle = Handle}, Value, Attrs) ->
  do_record(Handle, Value, Attrs);
record(_, _, _) ->
  {error, invalid_operation}.

%% @doc Sets a value on a Gauge.
-spec set(instrument(), number()) -> ok.
set(Instrument, Value) ->
  set(Instrument, Value, #{}).

%% @doc Sets a value on a Gauge with attributes.
-spec set(instrument(), number(), map()) -> ok.
set(#otel_instrument{kind = gauge, handle = Handle}, Value, Attrs) ->
  do_set(Handle, Value, Attrs);
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
-spec list_instruments() -> [instrument()].
list_instruments() ->
  Names = persistent_term:get(otel_instruments, []),
  lists:filtermap(fun(Name) ->
    case get_instrument(Name) of
      undefined -> false;
      Inst -> {true, Inst}
    end
  end, Names).

%% @doc Invokes all observable instrument callbacks.
%% This should be called before metrics collection to update observable values.
-spec collect_observables() -> ok.
collect_observables() ->
  Instruments = list_instruments(),
  lists:foreach(fun collect_observable/1, Instruments),
  ok.

collect_observable(#otel_instrument{kind = Kind, handle = {observable, Handle, Callback}})
    when Kind =:= observable_counter;
         Kind =:= observable_gauge;
         Kind =:= observable_up_down_counter ->
  try
    Value = Callback(),
    case Kind of
      observable_counter ->
        %% For observable counter, we set the cumulative value
        do_set(Handle, Value, #{});
      observable_gauge ->
        do_set(Handle, Value, #{});
      observable_up_down_counter ->
        do_set(Handle, Value, #{})
    end
  catch
    _:_ -> ok
  end;
collect_observable(_) ->
  ok.

%% @doc Unregisters an instrument by name.
%% This removes the instrument from persistent_term and unregisters the underlying metric.
-spec unregister_instrument(binary() | atom()) -> ok | {error, not_found}.
unregister_instrument(Name) when is_atom(Name) ->
  unregister_instrument(atom_to_binary(Name, utf8));
unregister_instrument(Name) when is_binary(Name) ->
  Key = {otel_instrument, Name},
  case persistent_term:get(Key, undefined) of
    undefined ->
      {error, not_found};
    #otel_instrument{handle = Handle} ->
      %% Unregister underlying metric
      _ = unregister_underlying_metric(Handle),
      %% Remove from persistent_term
      _ = persistent_term:erase(Key),
      %% Remove from names list
      Names = persistent_term:get(otel_instruments, []),
      NewNames = lists:delete(Name, Names),
      persistent_term:put(otel_instruments, NewNames),
      ok
  end.

%% @doc Unregisters all OTel instruments.
-spec unregister_all_instruments() -> ok.
unregister_all_instruments() ->
  Names = persistent_term:get(otel_instruments, []),
  lists:foreach(fun(Name) ->
    _ = unregister_instrument(Name)
  end, Names),
  ok.

unregister_underlying_metric(#metric{name = MetricName}) ->
  instrument:unregister(MetricName);
unregister_underlying_metric({observable, #metric{name = MetricName}, _Callback}) ->
  instrument:unregister(MetricName);
unregister_underlying_metric(_) ->
  ok.

%% ============================================================================
%% Internal Functions
%% ============================================================================

create_instrument(#meter{} = Meter, Name, Kind, Opts) when is_atom(Name) ->
  create_instrument(Meter, atom_to_binary(Name, utf8), Kind, Opts);
create_instrument(#meter{} = Meter, Name, Kind, Opts) when is_binary(Name), is_map(Opts) ->
  Description = maps:get(description, Opts, undefined),
  Unit = maps:get(unit, Opts, undefined),

  %% Check if already exists
  case get_instrument(Name) of
    undefined ->
      %% Create the underlying metric
      Handle = create_underlying_metric(Name, Kind, Opts),
      Instrument = #otel_instrument{
        name = Name,
        kind = Kind,
        description = Description,
        unit = Unit,
        meter = Meter,
        handle = Handle
      },
      %% Register the instrument
      register_instrument(Name, Instrument),
      Instrument;
    Existing ->
      Existing
  end.

create_observable_instrument(#meter{} = Meter, Name, Kind, Callback) when is_atom(Name) ->
  create_observable_instrument(Meter, atom_to_binary(Name, utf8), Kind, Callback);
create_observable_instrument(#meter{} = Meter, Name, Kind, Callback) when is_binary(Name), is_function(Callback, 0) ->
  case get_instrument(Name) of
    undefined ->
      %% Create a gauge that will be updated by callback
      Handle = create_underlying_metric(Name, gauge, #{}),
      Instrument = #otel_instrument{
        name = Name,
        kind = Kind,
        description = undefined,
        unit = undefined,
        meter = Meter,
        handle = {observable, Handle, Callback}
      },
      register_instrument(Name, Instrument),
      Instrument;
    Existing ->
      Existing
  end.

create_underlying_metric(Name, counter, _Opts) ->
  %% Use gauge NIF for counter (monotonic increments only)
  {ok, Ref} = instrument_nif:new_gauge(),
  Info = instrument_lib:mk_info(Name, <<>>),
  Metric = #metric{
    name = {otel, Name},
    handle = Ref,
    collect = {instrument_counter, collect, [Info, Ref]}
  },
  ok = instrument:register(Metric),
  Metric;

create_underlying_metric(Name, up_down_counter, _Opts) ->
  %% Use gauge NIF for up_down_counter
  {ok, Ref} = instrument_nif:new_gauge(),
  Info = instrument_lib:mk_info(Name, <<>>),
  Metric = #metric{
    name = {otel, Name},
    handle = Ref,
    collect = {instrument_gauge, collect, [Info, Ref]}
  },
  ok = instrument:register(Metric),
  Metric;

create_underlying_metric(Name, histogram, Opts) ->
  %% Use histogram NIF
  Boundaries = maps:get(boundaries, Opts, default_boundaries()),
  Metric = instrument_histogram:new_histogram(Name, <<>>, Boundaries),
  ok = instrument:register(Metric),
  Metric;

create_underlying_metric(Name, gauge, _Opts) ->
  %% Use gauge NIF
  {ok, Ref} = instrument_nif:new_gauge(),
  Info = instrument_lib:mk_info(Name, <<>>),
  Metric = #metric{
    name = {otel, Name},
    handle = Ref,
    collect = {instrument_gauge, collect, [Info, Ref]}
  },
  ok = instrument:register(Metric),
  Metric.

register_instrument(Name, Instrument) ->
  Key = {otel_instrument, Name},
  persistent_term:put(Key, Instrument),
  Names = persistent_term:get(otel_instruments, []),
  case lists:member(Name, Names) of
    true -> ok;
    false -> persistent_term:put(otel_instruments, [Name | Names])
  end.

do_add(#metric{handle = Ref}, Value, Attrs) when is_number(Value), map_size(Attrs) =:= 0 ->
  %% No attributes - use base metric directly
  instrument_nif:inc_gauge(Ref, float(Value));
do_add(#metric{handle = Ref} = _Metric, Value, Attrs) when is_number(Value), map_size(Attrs) > 0 ->
  %% With attributes - for now, fall back to base metric
  %% Future: create vector metrics for attribute cardinality
  instrument_nif:inc_gauge(Ref, float(Value));
do_add(_, _, _) ->
  {error, invalid_handle}.

do_record(#metric{} = Metric, Value, Attrs) when is_number(Value), map_size(Attrs) =:= 0 ->
  %% No attributes - use base metric directly
  instrument_histogram:observe_histogram(Metric, Value);
do_record(#metric{} = Metric, Value, Attrs) when is_number(Value), map_size(Attrs) > 0 ->
  %% With attributes - for now, fall back to base metric
  %% Future: create vector metrics for attribute cardinality
  instrument_histogram:observe_histogram(Metric, Value);
do_record(_, _, _) ->
  {error, invalid_handle}.

do_set(#metric{handle = Ref}, Value, Attrs) when is_number(Value), map_size(Attrs) =:= 0 ->
  %% No attributes - use base metric directly
  instrument_nif:set_gauge(Ref, float(Value));
do_set(#metric{handle = Ref} = _Metric, Value, Attrs) when is_number(Value), map_size(Attrs) > 0 ->
  %% With attributes - for now, fall back to base metric
  %% Future: create vector metrics for attribute cardinality
  instrument_nif:set_gauge(Ref, float(Value));
do_set(_, _, _) ->
  {error, invalid_handle}.

default_boundaries() ->
  %% Default histogram boundaries per OTel spec
  [0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1.0, 2.5, 5.0, 7.5, 10.0].
