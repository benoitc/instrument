%% Copyright (c) 2017, Benoit Chesneau <bchesneau@gmail.com>.
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
  Metrics = instrument_registry:collect_all(),
  iolist_to_binary([format_metric(M) || M <- Metrics]).

format_metric(#{type := counter} = M) ->
  format_counter(M);
format_metric(#{type := gauge} = M) ->
  format_gauge(M);
format_metric(#{type := histogram} = M) ->
  format_histogram(M);
format_metric(_) ->
  [].

%% Simple counter without labels
format_counter(#{name := Name, help := Help, val := Val}) ->
  NameBin = format_name(Name),
  TotalName = <<NameBin/binary, "_total">>,
  [
    <<"# HELP ">>, TotalName, <<" ">>, escape_help(Help), <<"\n">>,
    <<"# TYPE ">>, TotalName, <<" counter\n">>,
    TotalName, <<" ">>, format_value(Val), <<"\n">>
  ];
%% Counter vec with labels
format_counter(#{name := Name, help := Help, labels := Labels, data := Data}) ->
  NameBin = format_name(Name),
  TotalName = <<NameBin/binary, "_total">>,
  [
    <<"# HELP ">>, TotalName, <<" ">>, escape_help(Help), <<"\n">>,
    <<"# TYPE ">>, TotalName, <<" counter\n">>,
    [format_labeled_value(TotalName, Labels, LabelVals, Val)
     || {_LabelNames, LabelVals, Val} <- Data]
  ].

%% Simple gauge without labels
format_gauge(#{name := Name, help := Help, val := Val}) ->
  NameBin = format_name(Name),
  [
    <<"# HELP ">>, NameBin, <<" ">>, escape_help(Help), <<"\n">>,
    <<"# TYPE ">>, NameBin, <<" gauge\n">>,
    NameBin, <<" ">>, format_value(Val), <<"\n">>
  ];
%% Gauge vec with labels
format_gauge(#{name := Name, help := Help, labels := Labels, data := Data}) ->
  NameBin = format_name(Name),
  [
    <<"# HELP ">>, NameBin, <<" ">>, escape_help(Help), <<"\n">>,
    <<"# TYPE ">>, NameBin, <<" gauge\n">>,
    [format_labeled_value(NameBin, Labels, LabelVals, Val)
     || {_LabelNames, LabelVals, Val} <- Data]
  ].

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
%% Histogram vec with labels
format_histogram(#{name := Name, help := Help, labels := Labels, data := Data}) ->
  NameBin = format_name(Name),
  [
    <<"# HELP ">>, NameBin, <<" ">>, escape_help(Help), <<"\n">>,
    <<"# TYPE ">>, NameBin, <<" histogram\n">>,
    [format_histogram_data(NameBin, Labels, LabelVals, Val)
     || {_LabelNames, LabelVals, Val} <- Data]
  ].

format_histogram_data(Name, Labels, LabelVals, #{count := Count, sum := Sum, buckets := Buckets}) ->
  [
    format_histogram_buckets(Name, lists:zip(Labels, LabelVals), Buckets),
    format_histogram_bucket_inf(Name, lists:zip(Labels, LabelVals), Count),
    format_labeled_value(<<Name/binary, "_sum">>, Labels, LabelVals, Sum),
    format_labeled_value(<<Name/binary, "_count">>, Labels, LabelVals, Count)
  ].

format_histogram_buckets(Name, LabelPairs, Buckets) ->
  [format_bucket(Name, LabelPairs, B) || B <- Buckets].

format_bucket(Name, LabelPairs, #{upper_bound := Le, cumulative_count := Count}) ->
  BucketLabels = LabelPairs ++ [{le, format_bucket_le(Le)}],
  [
    Name, <<"_bucket">>, format_labels(BucketLabels), <<" ">>,
    format_value(Count), <<"\n">>
  ].

format_histogram_bucket_inf(Name, LabelPairs, Count) ->
  BucketLabels = LabelPairs ++ [{le, <<"+Inf">>}],
  [
    Name, <<"_bucket">>, format_labels(BucketLabels), <<" ">>,
    format_value(Count), <<"\n">>
  ].

format_bucket_le(Le) when is_float(Le) ->
  float_to_binary(Le, [{decimals, 10}, compact]);
format_bucket_le(Le) when is_integer(Le) ->
  integer_to_binary(Le).

format_labeled_value(Name, Labels, LabelVals, Val) ->
  LabelPairs = lists:zip(Labels, LabelVals),
  [Name, format_labels(LabelPairs), <<" ">>, format_value(Val), <<"\n">>].

format_labels([]) ->
  <<>>;
format_labels(LabelPairs) ->
  Labels = lists:join(<<",">>, [format_label_pair(K, V) || {K, V} <- LabelPairs]),
  [<<"{">>, Labels, <<"}">>].

format_label_pair(Key, Value) ->
  KeyBin = format_label_name(Key),
  ValBin = escape_label_value(Value),
  [KeyBin, <<"=\"">>, ValBin, <<"\"">>].

format_name(Name) when is_atom(Name) ->
  atom_to_binary(Name, utf8);
format_name(Name) when is_list(Name) ->
  list_to_binary(Name);
format_name(Name) when is_binary(Name) ->
  Name.

format_label_name(Name) when is_atom(Name) ->
  atom_to_binary(Name, utf8);
format_label_name(Name) when is_list(Name) ->
  list_to_binary(Name);
format_label_name(Name) when is_binary(Name) ->
  Name.

format_value(Val) when is_float(Val) ->
  float_to_binary(Val, [{decimals, 10}, compact]);
format_value(Val) when is_integer(Val) ->
  integer_to_binary(Val).

escape_help(Help) when is_binary(Help) ->
  escape_help_chars(Help);
escape_help(Help) when is_list(Help) ->
  escape_help_chars(list_to_binary(Help)).

escape_help_chars(Bin) ->
  binary:replace(
    binary:replace(Bin, <<"\\">>, <<"\\\\">>, [global]),
    <<"\n">>, <<"\\n">>, [global]).

escape_label_value(Val) when is_binary(Val) ->
  escape_label_chars(Val);
escape_label_value(Val) when is_list(Val) ->
  escape_label_chars(list_to_binary(Val));
escape_label_value(Val) when is_atom(Val) ->
  escape_label_chars(atom_to_binary(Val, utf8)).

escape_label_chars(Bin) ->
  B1 = binary:replace(Bin, <<"\\">>, <<"\\\\">>, [global]),
  B2 = binary:replace(B1, <<"\"">>, <<"\\\"">>, [global]),
  binary:replace(B2, <<"\n">>, <<"\\n">>, [global]).
