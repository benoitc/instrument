%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Stub exporter used by instrument_batch_async_SUITE. Sleeps for a
%% configurable duration on each export/2 call to simulate a slow backend.
-module(instrument_batch_async_SUITE_exporter).

-export([init/1, export/2, shutdown/1, force_flush/1]).

-define(STUB, instrument_batch_async_SUITE_stub).

init(_Config) ->
  {ok, #{}}.

export(_Spans, State) ->
  case ets:lookup(?STUB, sleep_ms) of
    [{sleep_ms, Ms}] when Ms > 0 -> timer:sleep(Ms);
    _ -> ok
  end,
  {ok, State}.

shutdown(_State) -> ok.
force_flush(State) -> {ok, State}.
