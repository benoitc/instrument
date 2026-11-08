%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Simple span processor that exports spans immediately.
%%
%% This processor exports each span as soon as it ends, without batching.
%% Suitable for development and debugging, but not recommended for
%% production due to performance overhead.
%%
%% == Configuration ==
%% - `exporter': Exporter module (required)
%% - `exporter_config': Configuration for the exporter (default: #{})
%%
%% == Example ==
%% ```
%% instrument_span_processor:register(instrument_span_processor_simple, #{
%%   exporter => instrument_exporter_console,
%%   exporter_config => #{format => text}
%% }).
%% '''
-module(instrument_span_processor_simple).
-author("benoitc").

-behaviour(instrument_span_processor).

-include("instrument_otel.hrl").

%% Processor callbacks
-export([
  init/1,
  on_start/2,
  on_end/1,
  shutdown/0,
  shutdown/1,
  force_flush/0,
  force_flush/1
]).

-define(SERVER, instrument_span_processor_simple_exporter).
-define(DEFAULT_EXPORT_TIMEOUT, 30000).

%% The exporter and its state live in an instrument_export_server registered
%% as ?SERVER; this record, written once at init, only says how to reach it.
-record(state, {
  exporter :: module(),
  export_timeout = ?DEFAULT_EXPORT_TIMEOUT :: pos_integer()
}).

%% @doc Initializes the processor and starts the server that owns the
%% exporter. Options: `exporter' (required), `exporter_config',
%% `export_timeout_millis' (default 30000).
-spec init(map()) -> {ok, #state{}} | {error, term()}.
init(Config) ->
  Exporter = maps:get(exporter, Config),
  ExporterConfig = maps:get(exporter_config, Config, #{}),
  Timeout = case maps:get(export_timeout_millis, Config, ?DEFAULT_EXPORT_TIMEOUT) of
              T when is_integer(T), T > 0 -> T;
              _ -> ?DEFAULT_EXPORT_TIMEOUT
            end,
  case instrument_export_server:start(?SERVER, Exporter, ExporterConfig, Timeout) of
    ok ->
      State = #state{exporter = Exporter, export_timeout = Timeout},
      persistent_term:put({?MODULE, state}, State),
      {ok, State};
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Called when a span starts. Returns the span unchanged.
-spec on_start(#span{}, #span_ctx{} | undefined) -> #span{}.
on_start(Span, _ParentCtx) ->
  Span.

%% @doc Called when a span ends. Exports the span and waits for the export;
%% exports from concurrent callers are serialized by the exporter's server.
-spec on_end(#span{}) -> ok.
on_end(#span{is_recording = false}) ->
  %% Don't export non-recording spans
  ok;
on_end(Span) ->
  case persistent_term:get({?MODULE, state}, undefined) of
    undefined -> ok;
    #state{export_timeout = Timeout} ->
      instrument_export_server:export(?SERVER, [Span], Timeout)
  end.

%% @doc Shuts down the processor and its exporter.
-spec shutdown() -> ok.
shutdown() ->
  case persistent_term:get({?MODULE, state}, undefined) of
    undefined -> ok;
    #state{} ->
      instrument_export_server:stop(?SERVER),
      persistent_term:erase({?MODULE, state})
  end,
  ok.

%% @doc Shuts down the processor with state.
-spec shutdown(#state{}) -> ok.
shutdown(#state{}) ->
  shutdown().

%% @doc Forces the exporter to flush.
-spec force_flush() -> ok.
force_flush() ->
  case persistent_term:get({?MODULE, state}, undefined) of
    undefined -> ok;
    #state{export_timeout = Timeout} ->
      instrument_export_server:force_flush(?SERVER, Timeout)
  end.

%% @doc Forces a flush with state.
-spec force_flush(#state{}) -> ok.
force_flush(_State) ->
  force_flush().
