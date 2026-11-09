%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_prometheus).
-author("benoitc").

-export([format/0, content_type/0]).

-include("instrument.hrl").

%% @doc Returns the Prometheus content type header value
-spec content_type() -> binary().
content_type() ->
  <<"text/plain; version=0.0.4; charset=utf-8">>.

%% @doc Formats all registered metrics in Prometheus text exposition format
-spec format() -> binary().
format() ->
  %% Run observable callbacks first so their values are current for this scrape
  %% (removes the stale-observable footgun for Prometheus-only deployments).
  ok = instrument_meter:collect_observables(),
  Metrics = instrument_registry:collect_all(),
  iolist_to_binary([safe_format_metric(M) || M <- Metrics]).

%% A metric that cannot be rendered (unexpected collector output, a value the
%% formatter cannot print) is skipped and logged instead of failing the scrape.
safe_format_metric(M) ->
  try
    iolist_to_binary(format_metric(M))
  catch Class:Reason:Stacktrace ->
    logger:warning("Skipping metric ~p in Prometheus output: ~p:~p",
                   [maps:get(name, M, undefined), Class, Reason],
                   #{stacktrace => Stacktrace}),
    <<>>
  end.

-spec format_metric(map()) -> iolist().
%% A family with no rows emits nothing (the phantom-zero series is gone).
format_metric(#{data := []}) ->
  [];
format_metric(#{type := counter} = M) ->
  format_counter(M);
format_metric(#{type := gauge} = M) ->
  format_gauge(M);
format_metric(#{type := histogram} = M) ->
  format_histogram(M);
format_metric(_) ->
  [].

-spec format_counter(map()) -> iolist().
%% Simple counter without labels
format_counter(#{name := Name, help := Help, val := Val}) ->
  NameBin = format_name(Name),
  TotalName = <<NameBin/binary, "_total">>,
  [
    <<"# HELP ">>, TotalName, <<" ">>, escape_help(Help), <<"\n">>,
    <<"# TYPE ">>, TotalName, <<" counter\n">>,
    TotalName, <<" ">>, format_value(Val), <<"\n">>
  ];
%% Counter family with labels (one row per live label set; each row padded
%% against the family-union label set, absent keys rendered as "").
format_counter(#{name := Name, help := Help, labels := Union, data := Data}) ->
  NameBin = format_name(Name),
  TotalName = <<NameBin/binary, "_total">>,
  [
    <<"# HELP ">>, TotalName, <<" ">>, escape_help(Help), <<"\n">>,
    <<"# TYPE ">>, TotalName, <<" counter\n">>,
    [format_value_pairs(TotalName, pad_row(Union, RowNames, RowVals), Val)
     || {RowNames, RowVals, Val} <- Data]
  ].

-spec format_gauge(map()) -> iolist().
%% Simple gauge without labels
format_gauge(#{name := Name, help := Help, val := Val}) ->
  NameBin = format_name(Name),
  [
    <<"# HELP ">>, NameBin, <<" ">>, escape_help(Help), <<"\n">>,
    <<"# TYPE ">>, NameBin, <<" gauge\n">>,
    NameBin, <<" ">>, format_value(Val), <<"\n">>
  ];
%% Gauge family with labels (per-row padded against the family union).
format_gauge(#{name := Name, help := Help, labels := Union, data := Data}) ->
  NameBin = format_name(Name),
  [
    <<"# HELP ">>, NameBin, <<" ">>, escape_help(Help), <<"\n">>,
    <<"# TYPE ">>, NameBin, <<" gauge\n">>,
    [format_value_pairs(NameBin, pad_row(Union, RowNames, RowVals), Val)
     || {RowNames, RowVals, Val} <- Data]
  ].

-spec format_histogram(map()) -> iolist().
%% Simple histogram without labels
format_histogram(#{name := Name, help := Help, count := Count, sum := Sum, buckets := Buckets}) ->
  NameBin = format_name(Name),
  [
    <<"# HELP ">>, NameBin, <<" ">>, escape_help(Help), <<"\n">>,
    <<"# TYPE ">>, NameBin, <<" histogram\n">>,
    format_histogram_buckets(NameBin, [], Buckets),
    format_histogram_bucket_inf(NameBin, [], Count),
    NameBin, <<"_sum ">>, format_value(Sum), <<"\n">>,
    NameBin, <<"_count ">>, format_value(Count), <<"\n">>
  ];
%% Histogram family with labels (per-row padded against the family union).
format_histogram(#{name := Name, help := Help, labels := Union, data := Data}) ->
  NameBin = format_name(Name),
  [
    <<"# HELP ">>, NameBin, <<" ">>, escape_help(Help), <<"\n">>,
    <<"# TYPE ">>, NameBin, <<" histogram\n">>,
    [format_histogram_data(NameBin, pad_row(Union, RowNames, RowVals), Val)
     || {RowNames, RowVals, Val} <- Data]
  ].

-spec format_histogram_data(binary(), list(), map()) -> iolist().
format_histogram_data(Name, LabelPairs, #{count := Count, sum := Sum, buckets := Buckets}) ->
  [
    format_histogram_buckets(Name, LabelPairs, Buckets),
    format_histogram_bucket_inf(Name, LabelPairs, Count),
    format_value_pairs(<<Name/binary, "_sum">>, LabelPairs, Sum),
    format_value_pairs(<<Name/binary, "_count">>, LabelPairs, Count)
  ].

-spec format_histogram_buckets(binary(), list(), list()) -> iolist().
format_histogram_buckets(Name, LabelPairs, Buckets) ->
  %% Filter out +Inf bucket (handled separately by format_histogram_bucket_inf)
  FiniteBuckets = [B || B <- Buckets, maps:get(upper_bound, B) =/= infinity],
  [format_bucket(Name, LabelPairs, B) || B <- FiniteBuckets].

-spec format_bucket(binary(), list(), map()) -> iolist().
format_bucket(Name, LabelPairs, #{upper_bound := Le, cumulative_count := Count}) ->
  BucketLabels = LabelPairs ++ [{le, format_bucket_le(Le)}],
  [
    Name, <<"_bucket">>, format_labels(BucketLabels), <<" ">>,
    format_value(Count), <<"\n">>
  ].

-spec format_histogram_bucket_inf(binary(), list(), number()) -> iolist().
format_histogram_bucket_inf(Name, LabelPairs, Count) ->
  BucketLabels = LabelPairs ++ [{le, <<"+Inf">>}],
  [
    Name, <<"_bucket">>, format_labels(BucketLabels), <<" ">>,
    format_value(Count), <<"\n">>
  ].

-spec format_bucket_le(number()) -> binary().
format_bucket_le(Le) when is_float(Le) ->
  float_to_binary(Le, [{decimals, 10}, compact]);
format_bucket_le(Le) when is_integer(Le) ->
  integer_to_binary(Le).

-spec format_value_pairs(binary(), list(), number()) -> iolist().
format_value_pairs(Name, LabelPairs, Val) ->
  [Name, format_labels(LabelPairs), <<" ">>, format_value(Val), <<"\n">>].

%% Pad a row's own label names/values against the family union; keys the row
%% does not carry render as empty strings. Fast clause: the row's names ARE the
%% union (homogeneous family / single key-set), so just zip.
-spec pad_row(list(), list(), list()) -> [{term(), term()}].
pad_row(Union, Union, Vals) ->
  lists:zip(Union, Vals);
pad_row(Union, Names, Vals) ->
  Pairs = maps:from_list(lists:zip(Names, Vals)),
  [{L, maps:get(L, Pairs, <<>>)} || L <- Union].

-spec format_labels(list()) -> iolist() | binary().
format_labels([]) ->
  <<>>;
format_labels(LabelPairs) ->
  Labels = lists:join(<<",">>, [format_label_pair(K, V) || {K, V} <- LabelPairs]),
  [<<"{">>, Labels, <<"}">>].

-spec format_label_pair(term(), term()) -> iolist().
format_label_pair(Key, Value) ->
  KeyBin = format_label_name(Key),
  ValBin = escape_label_value(Value),
  [KeyBin, <<"=\"">>, ValBin, <<"\"">>].

%% Metric and label names are restricted to the text format's character sets:
%% `[a-zA-Z_:][a-zA-Z0-9_:]*' for metrics and `[a-zA-Z_][a-zA-Z0-9_]*' for
%% labels. Other characters, such as the dots of OpenTelemetry names
%% (`http.server.duration'), become `_'. Without this one such name makes
%% Prometheus reject the whole scrape, and a crafted label name could inject
%% lines.
-spec format_name(term()) -> binary().
format_name({otel, Name}) -> sanitize_name(to_name_bin(Name), metric);
format_name(Name) -> sanitize_name(to_name_bin(Name), metric).

-spec format_label_name(term()) -> binary().
format_label_name(Name) ->
  sanitize_name(to_name_bin(Name), label).

to_name_bin(Name) when is_binary(Name) -> Name;
to_name_bin(Name) when is_atom(Name) -> atom_to_binary(Name, utf8);
to_name_bin(Name) when is_list(Name) ->
  try unicode:characters_to_binary(Name) of
    B when is_binary(B) -> B;
    _ -> printed(Name)
  catch _:_ -> printed(Name)
  end;
to_name_bin(Name) -> printed(Name).

printed(Term) ->
  unicode:characters_to_binary(io_lib:format("~0tp", [Term])).

sanitize_name(<<>>, _Kind) ->
  <<"_">>;
sanitize_name(Bin, Kind) ->
  case valid_name(Bin, Kind, true) of
    true -> Bin;
    false ->
      Clean = << <<(name_char(C, Kind))>> || <<C>> <= Bin >>,
      case Clean of
        <<D, _/binary>> when D >= $0, D =< $9 -> <<"_", Clean/binary>>;
        _ -> Clean
      end
  end.

valid_name(<<>>, _Kind, _First) -> true;
valid_name(<<C, Rest/binary>>, Kind, First) ->
  Ok = (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse C =:= $_
       orelse (Kind =:= metric andalso C =:= $:)
       orelse (not First andalso C >= $0 andalso C =< $9),
  Ok andalso valid_name(Rest, Kind, false).

name_char(C, _) when C >= $a, C =< $z -> C;
name_char(C, _) when C >= $A, C =< $Z -> C;
name_char(C, _) when C >= $0, C =< $9 -> C;
name_char($_, _) -> $_;
name_char($:, metric) -> $:;
name_char(_, _) -> $_.

-spec format_value(number()) -> binary().
format_value(Val) when is_float(Val) ->
  float_to_binary(Val, [{decimals, 10}, compact]);
format_value(Val) when is_integer(Val) ->
  integer_to_binary(Val).

-spec escape_help(binary() | list()) -> binary().
escape_help(Help) when is_binary(Help) ->
  escape_help_chars(Help);
escape_help(Help) ->
  escape_help_chars(to_name_bin(Help)).

-spec escape_help_chars(binary()) -> binary().
escape_help_chars(Bin) ->
  binary:replace(
    binary:replace(Bin, <<"\\">>, <<"\\\\">>, [global]),
    <<"\n">>, <<"\\n">>, [global]).

-spec escape_label_value(term()) -> binary().
escape_label_value(Val) when is_integer(Val) ->
  integer_to_binary(Val);
escape_label_value(Val) ->
  escape_label_chars(to_name_bin(Val)).

-spec escape_label_chars(binary()) -> binary().
escape_label_chars(Bin) ->
  B1 = binary:replace(Bin, <<"\\">>, <<"\\\\">>, [global]),
  B2 = binary:replace(B1, <<"\"">>, <<"\\\"">>, [global]),
  binary:replace(B2, <<"\n">>, <<"\\n">>, [global]).
