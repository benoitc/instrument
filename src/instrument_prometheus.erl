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
  iolist_to_binary([format_metric(M) || M <- Metrics]).

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

-spec format_name(atom() | list() | binary() | tuple()) -> binary().
format_name({otel, Name}) when is_binary(Name) -> Name;
format_name(Name) when is_atom(Name) ->
  atom_to_binary(Name, utf8);
format_name(Name) when is_list(Name) ->
  list_to_binary(Name);
format_name(Name) when is_binary(Name) ->
  Name.

-spec format_label_name(atom() | list() | binary()) -> binary().
format_label_name(Name) when is_atom(Name) ->
  atom_to_binary(Name, utf8);
format_label_name(Name) when is_list(Name) ->
  list_to_binary(Name);
format_label_name(Name) when is_binary(Name) ->
  Name.

-spec format_value(number()) -> binary().
format_value(Val) when is_float(Val) ->
  float_to_binary(Val, [{decimals, 10}, compact]);
format_value(Val) when is_integer(Val) ->
  integer_to_binary(Val).

-spec escape_help(binary() | list()) -> binary().
escape_help(Help) when is_binary(Help) ->
  escape_help_chars(Help);
escape_help(Help) when is_list(Help) ->
  escape_help_chars(list_to_binary(Help)).

-spec escape_help_chars(binary()) -> binary().
escape_help_chars(Bin) ->
  binary:replace(
    binary:replace(Bin, <<"\\">>, <<"\\\\">>, [global]),
    <<"\n">>, <<"\\n">>, [global]).

-spec escape_label_value(binary() | list() | atom()) -> binary().
escape_label_value(Val) when is_binary(Val) ->
  escape_label_chars(Val);
escape_label_value(Val) when is_list(Val) ->
  escape_label_chars(list_to_binary(Val));
escape_label_value(Val) when is_atom(Val) ->
  escape_label_chars(atom_to_binary(Val, utf8)).

-spec escape_label_chars(binary()) -> binary().
escape_label_chars(Bin) ->
  B1 = binary:replace(Bin, <<"\\">>, <<"\\\\">>, [global]),
  B2 = binary:replace(B1, <<"\"">>, <<"\\\"">>, [global]),
  binary:replace(B2, <<"\n">>, <<"\\n">>, [global]).
