%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Stub exporter used by instrument_otlp_retry_SUITE. Each export/2 call
%% consumes the next scripted response from an ETS table.
-module(instrument_otlp_retry_SUITE_exporter).

-export([init/1, export/2, shutdown/1, force_flush/1]).

-define(STUB, instrument_otlp_retry_SUITE_stub).

init(_Config) ->
  {ok, #{}}.

export(_Spans, State) ->
  _ = ets:update_counter(?STUB, calls, {2, 1}, {calls, 0}),
  Response = case ets:lookup(?STUB, responses) of
               [{responses, [H | Rest]}] ->
                 ets:insert(?STUB, {responses, Rest}),
                 H;
               _ ->
                 ok
             end,
  case Response of
    ok -> {ok, State};
    {error, Kind, _Reason} -> {error, Kind, State}
  end.

shutdown(_State) -> ok.
force_flush(State) -> {ok, State}.
