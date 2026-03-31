%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Console exporter for metrics.
%%
%% Exports metrics to stdout for debugging and development.
%%
%% == Example Usage ==
%% ```
%% %% Register with default options
%% instrument_metrics_exporter:register(instrument_metrics_exporter_console:new()),
%%
%% %% Register with options
%% instrument_metrics_exporter:register(instrument_metrics_exporter_console:new(#{
%%     format => json,      %% json | text (default: text)
%%     output => standard_io %% standard_io | standard_error | {file, Path}
%% })),
%% '''
-module(instrument_metrics_exporter_console).
-author("benoitc").

%% Public API
-export([new/0, new/1]).

%% Exporter callbacks
-export([init/1, export/2, shutdown/1, force_flush/1]).

-record(state, {
  format = text :: text | json,
  output = standard_io :: standard_io | standard_error | {file, file:io_device()}
}).

%% ============================================================================
%% Public API
%% ============================================================================

%% @doc Creates a new console exporter configuration with defaults.
-spec new() -> #{module := module(), config := map()}.
new() ->
  new(#{}).

%% @doc Creates a new console exporter configuration.
-spec new(map()) -> #{module := module(), config := map()}.
new(Config) when is_map(Config) ->
  #{module => ?MODULE, config => Config}.

%% ============================================================================
%% Exporter callbacks
%% ============================================================================

%% @doc Initializes the exporter.
-spec init(map()) -> {ok, #state{}} | {error, term()}.
init(Config) ->
  Format = maps:get(format, Config, text),
  OutputSpec = maps:get(output, Config, standard_io),
  case open_output(OutputSpec) of
    {ok, Output} ->
      {ok, #state{format = Format, output = Output}};
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Exports metrics to the console.
-spec export([map()], #state{}) -> {ok, #state{}} | {error, term(), #state{}}.
export(Metrics, #state{format = Format, output = Output} = State) ->
  try
    lists:foreach(fun(Metric) ->
      Line = format_metric(Metric, Format),
      io:put_chars(Output, Line)
    end, Metrics),
    {ok, State}
  catch
    _:Reason ->
      {error, Reason, State}
  end.

%% @doc Shuts down the exporter.
-spec shutdown(#state{}) -> ok.
shutdown(#state{output = {file, Fd}}) ->
  file:close(Fd),
  ok;
shutdown(_State) ->
  ok.

%% @doc Forces a flush (no-op for console).
-spec force_flush(#state{}) -> {ok, #state{}}.
force_flush(State) ->
  {ok, State}.

%% ============================================================================
%% Internal functions
%% ============================================================================

open_output(standard_io) ->
  {ok, standard_io};
open_output(standard_error) ->
  {ok, standard_error};
open_output({file, Path}) ->
  case file:open(Path, [write, append]) of
    {ok, Fd} -> {ok, {file, Fd}};
    Error -> Error
  end.

format_metric(Metric, text) ->
  format_metric_text(Metric);
format_metric(Metric, json) ->
  format_metric_json(Metric).

format_metric_text(#{name := Name, type := Type, data_points := DataPoints} = Metric) ->
  Description = maps:get(description, Metric, <<>>),
  Timestamp = format_timestamp(erlang:system_time(nanosecond)),
  Lines = lists:map(fun(DataPoint) ->
    format_data_point_text(Name, Type, DataPoint, Timestamp)
  end, DataPoints),
  DescLine = case Description of
    <<>> -> "";
    _ -> io_lib:format("# ~s~n", [Description])
  end,
  [DescLine | Lines].

format_data_point_text(Name, histogram, #{attributes := Attrs, value := Value}, Timestamp) ->
  #{count := Count, sum := Sum, buckets := Buckets} = Value,
  AttrsStr = format_labels_text(Attrs),
  BucketLines = lists:map(fun(#{bound := Bound, count := BCount}) ->
    BoundStr = case Bound of
      infinity -> "+Inf";
      _ -> format_number(Bound)
    end,
    io_lib:format("[~s] ~s_bucket{~sle=\"~s\"} ~p~n",
      [Timestamp, Name, AttrsStr, BoundStr, BCount])
  end, Buckets),
  SumLine = io_lib:format("[~s] ~s_sum{~s} ~s~n", [Timestamp, Name, format_labels_text_plain(Attrs), format_number(Sum)]),
  CountLine = io_lib:format("[~s] ~s_count{~s} ~p~n", [Timestamp, Name, format_labels_text_plain(Attrs), Count]),
  [BucketLines, SumLine, CountLine];

format_data_point_text(Name, _Type, #{attributes := Attrs, value := Value}, Timestamp) ->
  AttrsStr = format_labels_text_plain(Attrs),
  ValueStr = format_number(Value),
  io_lib:format("[~s] ~s{~s} ~s~n", [Timestamp, Name, AttrsStr, ValueStr]).

format_labels_text(Attrs) when map_size(Attrs) =:= 0 ->
  "";
format_labels_text(Attrs) ->
  Pairs = maps:fold(fun(K, V, Acc) ->
    [io_lib:format("~s=\"~s\",", [K, V]) | Acc]
  end, [], Attrs),
  lists:flatten(lists:reverse(Pairs)).

format_labels_text_plain(Attrs) when map_size(Attrs) =:= 0 ->
  "";
format_labels_text_plain(Attrs) ->
  Pairs = maps:fold(fun(K, V, Acc) ->
    [io_lib:format("~s=\"~s\"", [K, V]) | Acc]
  end, [], Attrs),
  string:join([lists:flatten(P) || P <- lists:reverse(Pairs)], ",").

format_metric_json(#{name := Name, type := Type, data_points := DataPoints} = Metric) ->
  Description = maps:get(description, Metric, <<>>),
  Unit = maps:get(unit, Metric, <<"1">>),
  MetricMap = #{
    <<"name">> => Name,
    <<"description">> => Description,
    <<"unit">> => Unit,
    <<"type">> => atom_to_binary(Type, utf8),
    <<"dataPoints">> => [format_data_point_json(Type, DP) || DP <- DataPoints]
  },
  [json:encode(MetricMap), "\n"].

format_data_point_json(histogram, #{attributes := Attrs, value := Value, timestamp := Ts}) ->
  #{count := Count, sum := Sum, buckets := Buckets} = Value,
  #{
    <<"attributes">> => format_attributes_json(Attrs),
    <<"timeUnixNano">> => Ts,
    <<"count">> => Count,
    <<"sum">> => Sum,
    <<"bucketCounts">> => [maps:get(count, B) || B <- Buckets],
    <<"explicitBounds">> => [maps:get(bound, B) || B <- Buckets, maps:get(bound, B) =/= infinity]
  };

format_data_point_json(_Type, #{attributes := Attrs, value := Value, timestamp := Ts}) ->
  #{
    <<"attributes">> => format_attributes_json(Attrs),
    <<"timeUnixNano">> => Ts,
    <<"value">> => Value
  }.

format_attributes_json(Attrs) ->
  maps:fold(fun(K, V, Acc) ->
    Key = to_binary(K),
    maps:put(Key, format_attr_value(V), Acc)
  end, #{}, Attrs).

format_attr_value(V) when is_binary(V) -> V;
format_attr_value(V) when is_atom(V) -> atom_to_binary(V, utf8);
format_attr_value(V) when is_integer(V) -> V;
format_attr_value(V) when is_float(V) -> V;
format_attr_value(V) when is_boolean(V) -> V;
format_attr_value(V) when is_list(V) -> [format_attr_value(E) || E <- V];
format_attr_value(V) -> iolist_to_binary(io_lib:format("~p", [V])).

format_timestamp(Ts) ->
  Micros = Ts div 1000,
  Seconds = Micros div 1000000,
  Micro = Micros rem 1000000,
  {{Y, M, D}, {H, Mi, S}} = calendar:system_time_to_universal_time(Seconds, second),
  io_lib:format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0B.~6..0BZ",
    [Y, M, D, H, Mi, S, Micro]).

format_number(V) when is_integer(V) -> integer_to_list(V);
format_number(V) when is_float(V) -> float_to_list(V, [{decimals, 6}, compact]);
format_number(infinity) -> "+Inf".

to_binary(V) when is_binary(V) -> V;
to_binary(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_binary(V) when is_list(V) -> list_to_binary(V).
