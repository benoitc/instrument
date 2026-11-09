%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @private Owns the library's shared ETS tables.
%%
%% Started first by instrument_sup and does nothing else, so it has no reason
%% to crash. Keeping the tables here means a crash of the registry or of an
%% exporter process does not delete metric data or registrations: only an
%% application restart starts from a clean slate, which this process's init
%% enforces by sweeping instrument-owned persistent_term entries.
-module(instrument_table_owner).

-behaviour(gen_server).

-export([start_link/0]).

-export([
  init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3
]).

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
  %% Clean slate: erase persistent_term entries left by a previous run of the
  %% application, then create the tables and re-mint the family counter.
  ok = instrument_registry:clear_instrument_persistent_terms(),
  ok = instrument_registry:create_label_counts_table(),
  ok = instrument_exemplar:init_table(),
  ok = instrument_meter:init_callback_table(),
  ok = instrument_series:init(),
  ok = instrument_registrations:init(),
  {ok, #{}}.

handle_call(_Request, _From, State) ->
  {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.
