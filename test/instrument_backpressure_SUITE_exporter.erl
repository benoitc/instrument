%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Stub span exporter for instrument_backpressure_SUITE. Records the size
%% of every export, flags concurrent calls, and sleeps for `sleep_ms'.
-module(instrument_backpressure_SUITE_exporter).

-export([init/1, export/2, shutdown/1, force_flush/1]).

-define(TAB, instrument_backpressure_SUITE_stub).

init(Config) ->
  {ok, Config}.

export(Spans, State) ->
  case ets:update_counter(?TAB, inflight, 1) of
    1 -> ok;
    _ -> ets:insert(?TAB, {overlap, true})
  end,
  ets:insert(?TAB, {{call, erlang:unique_integer()}, length(Spans)}),
  case ets:lookup(?TAB, sleep_ms) of
    [{sleep_ms, Ms}] when Ms > 0 -> timer:sleep(Ms);
    _ -> ok
  end,
  ets:update_counter(?TAB, inflight, -1),
  {ok, State}.

shutdown(_State) -> ok.

force_flush(State) -> {ok, State}.
