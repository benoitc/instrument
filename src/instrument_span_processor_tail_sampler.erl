%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Tail-based sampling span processor.
%%
%% Makes sampling decisions after spans complete, enabling filtering based on:
%% - Error status (always keep errors)
%% - Duration (keep slow operations)
%% - Final attribute values
%% - Span events (exceptions, specific events)
%%
%% == Configuration ==
%% - `always_keep': List of rules; spans matching any rule are kept
%% - `always_drop': List of rules; spans matching any rule are dropped
%% - `default_ratio': Probability (0.0-1.0) for remaining spans
%% - `exporter': Exporter module to forward kept spans
%% - `exporter_config': Configuration for the exporter
%%
%% == Rule Types ==
%% - `{status, error | ok}' - Match span status
%% - `{duration_ms, Op, Value}' - Match duration (Op: '>', '<', '>=', '<=')
%% - `{attribute, Key, Value}' - Exact attribute match
%% - `{attribute_exists, Key}' - Attribute is present
%% - `{has_event, EventName}' - Span has named event
%% - `has_exception' - Span has exception event
%%
%% == Example ==
%% ```
%% instrument_span_processor:register(instrument_span_processor_tail_sampler, #{
%%   always_keep => [
%%     {status, error},
%%     {duration_ms, '>', 100},
%%     {attribute, <<"priority">>, high}
%%   ],
%%   always_drop => [
%%     {attribute, <<"health_check">>, true}
%%   ],
%%   default_ratio => 0.01,
%%   exporter => instrument_exporter_console,
%%   exporter_config => #{}
%% }).
%% '''
-module(instrument_span_processor_tail_sampler).
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

%% Internal exports for testing
-export([
  matches_rule/2,
  should_keep/2
]).

-define(STATE_KEY, {?MODULE, state}).

-record(state, {
  always_keep = [] :: [rule()],
  always_drop = [] :: [rule()],
  default_ratio = 0.01 :: float(),
  exporter :: module() | undefined,
  exporter_state :: term()
}).

-type comparison_op() :: '>' | '<' | '>=' | '<='.

-type rule() ::
    {status, error | ok} |
    {duration_ms, comparison_op(), pos_integer()} |
    {attribute, binary(), term()} |
    {attribute_exists, binary()} |
    {has_event, binary()} |
    has_exception.

-export_type([rule/0, comparison_op/0]).

%% ============================================================================
%% Processor Callbacks
%% ============================================================================

%% @doc Initializes the tail sampler processor.
-spec init(map()) -> {ok, #state{}} | {error, term()}.
init(Config) ->
  AlwaysKeep = maps:get(always_keep, Config, []),
  AlwaysDrop = maps:get(always_drop, Config, []),
  DefaultRatio = maps:get(default_ratio, Config, 0.01),

  %% Validate rules
  case validate_rules(AlwaysKeep ++ AlwaysDrop) of
    ok ->
      %% Initialize exporter if configured
      case init_exporter(Config) of
        {ok, Exporter, ExporterState} ->
          State = #state{
            always_keep = AlwaysKeep,
            always_drop = AlwaysDrop,
            default_ratio = clamp_ratio(DefaultRatio),
            exporter = Exporter,
            exporter_state = ExporterState
          },
          persistent_term:put(?STATE_KEY, State),
          {ok, State};
        {error, Reason} ->
          {error, Reason}
      end;
    {error, Reason} ->
      {error, {invalid_rule, Reason}}
  end.

%% @doc Called when a span starts. Returns the span unchanged.
-spec on_start(#span{}, #span_ctx{} | undefined) -> #span{}.
on_start(Span, _ParentCtx) ->
  Span.

%% @doc Called when a span ends. Applies sampling rules and forwards or drops.
-spec on_end(#span{}) -> ok.
on_end(#span{is_recording = false}) ->
  %% Don't process non-recording spans
  ok;
on_end(Span) ->
  case persistent_term:get(?STATE_KEY, undefined) of
    undefined ->
      ok;
    State ->
      case should_keep(Span, State) of
        true ->
          export_span(Span, State);
        false ->
          ok
      end
  end,
  ok.

%% @doc Shuts down the processor.
-spec shutdown() -> ok.
shutdown() ->
  case persistent_term:get(?STATE_KEY, undefined) of
    undefined ->
      ok;
    #state{exporter = Exporter, exporter_state = ExporterState} ->
      catch shutdown_exporter(Exporter, ExporterState),
      persistent_term:erase(?STATE_KEY)
  end,
  ok.

%% @doc Shuts down the processor with state.
-spec shutdown(#state{}) -> ok.
shutdown(#state{exporter = Exporter, exporter_state = ExporterState}) ->
  catch shutdown_exporter(Exporter, ExporterState),
  persistent_term:erase(?STATE_KEY),
  ok.

%% @doc Forces a flush. Delegates to exporter if configured.
-spec force_flush() -> ok.
force_flush() ->
  case persistent_term:get(?STATE_KEY, undefined) of
    undefined ->
      ok;
    #state{exporter = undefined} ->
      ok;
    #state{exporter = Exporter, exporter_state = ExporterState} ->
      catch Exporter:force_flush(ExporterState),
      ok
  end.

%% @doc Forces a flush with state.
-spec force_flush(#state{}) -> ok.
force_flush(#state{exporter = undefined}) ->
  ok;
force_flush(#state{exporter = Exporter, exporter_state = ExporterState}) ->
  catch Exporter:force_flush(ExporterState),
  ok.

%% ============================================================================
%% Sampling Logic
%% ============================================================================

%% @doc Determines if a span should be kept based on rules.
-spec should_keep(#span{}, #state{}) -> boolean().
should_keep(Span, #state{always_keep = KeepRules, always_drop = DropRules,
                          default_ratio = Ratio}) ->
  %% 1. Check always_keep rules (OR logic)
  case matches_any_rule(Span, KeepRules) of
    true ->
      true;
    false ->
      %% 2. Check always_drop rules (OR logic)
      case matches_any_rule(Span, DropRules) of
        true ->
          false;
        false ->
          %% 3. Apply probabilistic sampling
          apply_probability(Span, Ratio)
      end
  end.

%% @doc Checks if span matches any rule in the list.
-spec matches_any_rule(#span{}, [rule()]) -> boolean().
matches_any_rule(_Span, []) ->
  false;
matches_any_rule(Span, [Rule | Rest]) ->
  case matches_rule(Span, Rule) of
    true -> true;
    false -> matches_any_rule(Span, Rest)
  end.

%% @doc Evaluates a single rule against a span.
-spec matches_rule(#span{}, rule()) -> boolean().

%% Status matching
matches_rule(#span{status = {error, _}}, {status, error}) ->
  true;
matches_rule(#span{status = ok}, {status, ok}) ->
  true;
matches_rule(_Span, {status, _}) ->
  false;

%% Duration matching (times are in nanoseconds)
matches_rule(#span{start_time = Start, end_time = End}, {duration_ms, Op, ThresholdMs})
    when is_integer(Start), is_integer(End), End >= Start ->
  DurationMs = (End - Start) div 1000000,  %% Convert ns to ms
  compare(DurationMs, Op, ThresholdMs);
matches_rule(#span{name = Name, end_time = undefined}, {duration_ms, _, _}) ->
  %% Span has no end_time - likely called before span ended
  logger:warning("Tail sampler: duration rule skipped for span ~p with undefined end_time",
                [Name],
                #{error_logger => #{tag => warning_msg}}),
  false;
matches_rule(_Span, {duration_ms, _, _}) ->
  %% Invalid start_time, end_time, or end < start
  false;

%% Attribute exact match
matches_rule(#span{attributes = Attrs}, {attribute, Key, Value}) ->
  maps:get(Key, Attrs, undefined) =:= Value;

%% Attribute exists
matches_rule(#span{attributes = Attrs}, {attribute_exists, Key}) ->
  maps:is_key(Key, Attrs);

%% Has named event
matches_rule(#span{events = Events}, {has_event, EventName}) ->
  lists:any(fun(#span_event{name = Name}) -> Name =:= EventName end, Events);

%% Has exception event
matches_rule(#span{events = Events}, has_exception) ->
  lists:any(fun(#span_event{name = Name}) -> Name =:= <<"exception">> end, Events);

%% Unknown rule - no match
matches_rule(_Span, _Rule) ->
  false.

%% @doc Compare two values using the given operator.
-spec compare(number(), comparison_op(), number()) -> boolean().
compare(A, '>', B) -> A > B;
compare(A, '<', B) -> A < B;
compare(A, '>=', B) -> A >= B;
compare(A, '<=', B) -> A =< B.

%% @doc Apply probabilistic sampling based on trace ID.
-spec apply_probability(#span{}, float()) -> boolean().
apply_probability(_Span, Ratio) when Ratio >= 1.0 ->
  true;
apply_probability(_Span, Ratio) when Ratio =< 0.0 ->
  false;
apply_probability(#span{ctx = #span_ctx{trace_id = TraceId}}, Ratio) when is_binary(TraceId) ->
  %% Use trace ID for deterministic sampling (same trace = same decision)
  <<HashInt:64, _/binary>> = TraceId,
  Threshold = trunc(Ratio * 18446744073709551615),  %% max uint64
  HashInt =< Threshold;
apply_probability(_Span, Ratio) ->
  %% Fallback to random if no valid trace ID
  rand:uniform() =< Ratio.

%% ============================================================================
%% Internal Functions
%% ============================================================================

%% @private Initialize exporter if configured.
-spec init_exporter(map()) -> {ok, module() | undefined, term()} | {error, term()}.
init_exporter(Config) ->
  case maps:get(exporter, Config, undefined) of
    undefined ->
      {ok, undefined, undefined};
    Exporter ->
      ExporterConfig = maps:get(exporter_config, Config, #{}),
      case Exporter:init(ExporterConfig) of
        {ok, ExporterState} ->
          {ok, Exporter, ExporterState};
        {error, Reason} ->
          {error, {exporter_init_failed, Reason}}
      end
  end.

%% @private Export a span to the configured exporter.
-spec export_span(#span{}, #state{}) -> ok.
export_span(_Span, #state{exporter = undefined}) ->
  ok;
export_span(Span, #state{exporter = Exporter, exporter_state = ExporterState} = State) ->
  NewExporterState = try
    case Exporter:export([Span], ExporterState) of
      {ok, NewState} -> NewState;
      {error, _Reason, NewState} -> NewState;
      _ -> ExporterState
    end
  catch
    Class:Reason:Stacktrace ->
      logger:warning("Tail sampler export to ~p failed: ~p:~p",
                    [Exporter, Class, Reason],
                    #{error_logger => #{tag => warning_msg},
                      mfa => {Exporter, export, 2},
                      stacktrace => Stacktrace}),
      ExporterState
  end,
  %% Update persistent state with new exporter state
  persistent_term:put(?STATE_KEY, State#state{exporter_state = NewExporterState}),
  ok.

%% @private Shutdown exporter.
-spec shutdown_exporter(module() | undefined, term()) -> ok.
shutdown_exporter(undefined, _) ->
  ok;
shutdown_exporter(Exporter, ExporterState) ->
  catch Exporter:shutdown(ExporterState),
  ok.

%% @private Validate all rules.
-spec validate_rules([rule()]) -> ok | {error, term()}.
validate_rules([]) ->
  ok;
validate_rules([Rule | Rest]) ->
  case validate_rule(Rule) of
    ok -> validate_rules(Rest);
    {error, Reason} -> {error, Reason}
  end.

%% @private Validate a single rule.
-spec validate_rule(rule()) -> ok | {error, term()}.
validate_rule({status, error}) -> ok;
validate_rule({status, ok}) -> ok;
validate_rule({duration_ms, Op, Value}) when Op =:= '>'; Op =:= '<';
                                              Op =:= '>='; Op =:= '<=' ->
  case is_integer(Value) andalso Value >= 0 of
    true -> ok;
    false -> {error, {invalid_duration_value, Value}}
  end;
validate_rule({attribute, Key, _Value}) when is_binary(Key) -> ok;
validate_rule({attribute_exists, Key}) when is_binary(Key) -> ok;
validate_rule({has_event, Name}) when is_binary(Name) -> ok;
validate_rule(has_exception) -> ok;
validate_rule(Rule) -> {error, {unknown_rule, Rule}}.

%% @private Clamp ratio to valid range [0.0, 1.0].
-spec clamp_ratio(number()) -> float().
clamp_ratio(R) when R < 0.0 -> 0.0;
clamp_ratio(R) when R > 1.0 -> 1.0;
clamp_ratio(R) -> float(R).
