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

-record(state, {
  exporter :: module(),
  exporter_state :: term()
}).

%% ============================================================================
%% Processor Callbacks
%% ============================================================================

%% @doc Initializes the simple processor.
-spec init(map()) -> {ok, #state{}} | {error, term()}.
init(Config) ->
  Exporter = maps:get(exporter, Config),
  ExporterConfig = maps:get(exporter_config, Config, #{}),
  case Exporter:init(ExporterConfig) of
    {ok, ExporterState} ->
      State = #state{
        exporter = Exporter,
        exporter_state = ExporterState
      },
      persistent_term:put({?MODULE, state}, State),
      {ok, State};
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Called when a span starts. Returns the span unchanged.
-spec on_start(#span{}, #span_ctx{} | undefined) -> #span{}.
on_start(Span, _ParentCtx) ->
  Span.

%% @doc Called when a span ends. Exports the span immediately.
-spec on_end(#span{}) -> ok.
on_end(#span{is_recording = false}) ->
  %% Don't export non-recording spans
  ok;
on_end(Span) ->
  %% Get state from persistent_term (set during init)
  case persistent_term:get({?MODULE, state}, undefined) of
    undefined ->
      ok;
    #state{exporter = Exporter, exporter_state = ExporterState} = State ->
      try
        case Exporter:export([Span], ExporterState) of
          {ok, NewExporterState} ->
            persistent_term:put({?MODULE, state}, State#state{exporter_state = NewExporterState});
          {error, _Reason, NewExporterState} ->
            persistent_term:put({?MODULE, state}, State#state{exporter_state = NewExporterState});
          _ ->
            ok
        end
      catch
        _:_ -> ok
      end
  end,
  ok.

%% @doc Shuts down the processor.
-spec shutdown() -> ok.
shutdown() ->
  case persistent_term:get({?MODULE, state}, undefined) of
    undefined ->
      ok;
    #state{exporter = Exporter, exporter_state = ExporterState} ->
      try Exporter:shutdown(ExporterState) catch _:_ -> ok end,
      persistent_term:erase({?MODULE, state})
  end,
  ok.

%% @doc Shuts down the processor with state.
%% Ignores the passed state and uses current state from persistent_term,
%% as the exporter state may have been updated during span exports.
-spec shutdown(#state{}) -> ok.
shutdown(#state{}) ->
  shutdown().

%% @doc Forces a flush. No-op for simple processor since it exports immediately.
-spec force_flush() -> ok.
force_flush() ->
  ok.

%% @doc Forces a flush with state.
-spec force_flush(#state{}) -> ok.
force_flush(_State) ->
  ok.
