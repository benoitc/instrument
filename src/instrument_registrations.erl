%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @private Registered exporters and processors, kept outside the processes
%% that use them.
%%
%% When an exporter manager or the span processor manager restarts after a
%% crash, it reads its registrations back from here and initializes them
%% again, so export keeps working instead of silently stopping. The table is
%% owned by instrument_table_owner.
-module(instrument_registrations).

-export([
  init/0,
  put/3,
  delete/2,
  clear/1,
  list/1
]).

-define(TAB, instrument_registrations).

-type kind() :: span_exporter | metrics_exporter | log_exporter | span_processor.

-spec init() -> ok.
init() ->
  case ets:info(?TAB, name) of
    undefined -> _ = ets:new(?TAB, [set, public, named_table]), ok;
    _ -> ok
  end.

%% @doc Records `Module' registered with `Config' for `Kind'.
-spec put(kind(), module(), term()) -> ok.
put(Kind, Module, Config) ->
  safe(fun() ->
    ets:insert(?TAB, {{Kind, Module}, erlang:unique_integer([monotonic]), Config})
  end).

-spec delete(kind(), module()) -> ok.
delete(Kind, Module) ->
  safe(fun() -> ets:delete(?TAB, {Kind, Module}) end).

-spec clear(kind()) -> ok.
clear(Kind) ->
  safe(fun() -> ets:match_delete(?TAB, {{Kind, '_'}, '_', '_'}) end).

%% @doc Registrations for `Kind', oldest first.
-spec list(kind()) -> [{module(), term()}].
list(Kind) ->
  Rows = instrument_lib:safe_call(fun() ->
    ets:match_object(?TAB, {{Kind, '_'}, '_', '_'})
  end, []),
  [{M, C} || {{_, M}, _, C} <- lists:keysort(2, Rows)].

safe(Fun) ->
  _ = instrument_lib:safe_call(Fun, ok),
  ok.
