%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_context_SUITE).
-author("benoitc").

-export([
  all/0,
  init_per_suite/1,
  end_per_suite/1,
  init_per_testcase/2,
  end_per_testcase/2
]).

-export([
  new_context_is_empty/1,
  set_and_get_value/1,
  attach_and_detach/1,
  with_context/1,
  spawn_with_context/1,
  nested_attach_detach/1,
  set_current_no_leak/1,
  spawn_helpers_no_leak/1,
  propagation_spawn_no_leak/1,
  baggage_operations/1,
  baggage_encode_decode/1,
  propagation_spawn/1,
  propagation_inject_extract/1
]).

all() ->
  [
    new_context_is_empty,
    set_and_get_value,
    attach_and_detach,
    with_context,
    spawn_with_context,
    nested_attach_detach,
    set_current_no_leak,
    spawn_helpers_no_leak,
    propagation_spawn_no_leak,
    baggage_operations,
    baggage_encode_decode,
    propagation_spawn,
    propagation_inject_extract
  ].

init_per_suite(Config) ->
  ok = application:start(instrument),
  Config.

end_per_suite(Config) ->
  ok = application:stop(instrument),
  Config.

init_per_testcase(_, Config) ->
  %% Clean up context between tests
  erlang:erase('$instrument_context'),
  Config.

end_per_testcase(_, _Config) ->
  erlang:erase('$instrument_context'),
  ok.

%% ============================================================================
%% Context Tests
%% ============================================================================

new_context_is_empty(_Config) ->
  Ctx = instrument_context:new(),
  #{} = Ctx,
  undefined = instrument_context:get_value(Ctx, foo),
  ok.

set_and_get_value(_Config) ->
  Ctx = instrument_context:new(),
  Ctx2 = instrument_context:set_value(Ctx, key1, value1),
  value1 = instrument_context:get_value(Ctx2, key1),
  undefined = instrument_context:get_value(Ctx, key1),
  default = instrument_context:get_value(Ctx2, missing, default),
  ok.

attach_and_detach(_Config) ->
  Ctx = instrument_context:set_value(instrument_context:new(), my_key, my_value),
  Token = instrument_context:attach(Ctx),

  %% Current context should have the value
  Current = instrument_context:current(),
  my_value = instrument_context:get_value(Current, my_key),

  %% Detach should restore empty context
  ok = instrument_context:detach(Token),
  Current2 = instrument_context:current(),
  undefined = instrument_context:get_value(Current2, my_key),
  ok.

with_context(_Config) ->
  Ctx = instrument_context:set_value(instrument_context:new(), test_key, test_value),

  %% Run function with context
  Result = instrument_context:with_context(Ctx, fun() ->
    Current = instrument_context:current(),
    test_value = instrument_context:get_value(Current, test_key),
    success
  end),
  success = Result,

  %% Context should be restored after
  Current2 = instrument_context:current(),
  undefined = instrument_context:get_value(Current2, test_key),
  ok.

spawn_with_context(_Config) ->
  Parent = self(),
  Ctx = instrument_context:set_value(instrument_context:new(), spawn_key, spawn_value),
  _ = instrument_context:attach(Ctx),

  Pid = instrument_context:spawn_with_context(fun() ->
    Current = instrument_context:current(),
    Value = instrument_context:get_value(Current, spawn_key),
    Parent ! {self(), Value}
  end),

  receive
    {Pid, spawn_value} -> ok
  after 1000 ->
    ct:fail(timeout)
  end.

nested_attach_detach(_Config) ->
  Ctx1 = instrument_context:set_value(instrument_context:new(), level, 1),
  Token1 = instrument_context:attach(Ctx1),
  1 = instrument_context:get_value(instrument_context:current(), level),

  Ctx2 = instrument_context:set_value(instrument_context:new(), level, 2),
  Token2 = instrument_context:attach(Ctx2),
  2 = instrument_context:get_value(instrument_context:current(), level),

  %% Detach in order
  ok = instrument_context:detach(Token2),
  1 = instrument_context:get_value(instrument_context:current(), level),

  ok = instrument_context:detach(Token1),
  undefined = instrument_context:get_value(instrument_context:current(), level),
  ok.

set_current_no_leak(_Config) ->
  %% Count process dictionary entries before
  BeforeCount = count_context_entries(),

  %% Call set_current multiple times - should NOT create new entries
  Ctx1 = instrument_context:set_value(instrument_context:new(), key, value1),
  ok = instrument_context:set_current(Ctx1),
  value1 = instrument_context:get_value(instrument_context:current(), key),

  Ctx2 = instrument_context:set_value(instrument_context:new(), key, value2),
  ok = instrument_context:set_current(Ctx2),
  value2 = instrument_context:get_value(instrument_context:current(), key),

  Ctx3 = instrument_context:set_value(instrument_context:new(), key, value3),
  ok = instrument_context:set_current(Ctx3),
  value3 = instrument_context:get_value(instrument_context:current(), key),

  %% Count after - should only have 1 entry (the main context key)
  AfterCount = count_context_entries(),

  %% Should have at most 1 more entry than before (the main context)
  true = (AfterCount - BeforeCount) =< 1,
  ok.

spawn_helpers_no_leak(_Config) ->
  Parent = self(),
  Ctx = instrument_context:set_value(instrument_context:new(), spawn_key, spawn_value),
  ok = instrument_context:set_current(Ctx),

  %% Spawn process that checks for leaks
  Pid = instrument_context:spawn_with_context(fun() ->
    %% Should have the context
    spawn_value = instrument_context:get_value(instrument_context:current(), spawn_key),

    %% Should not have extra context history entries
    Count = count_context_entries(),
    Parent ! {self(), context_count, Count}
  end),

  receive
    {Pid, context_count, Count} ->
      %% Should have at most 1 entry (the main context key, no history tokens)
      true = Count =< 1
  after 1000 ->
    ct:fail(timeout)
  end.

%% Test that instrument_propagation spawn functions don't create dictionary leaks (Bug 4 fix)
propagation_spawn_no_leak(_Config) ->
  Parent = self(),
  Ctx = instrument_context:set_value(instrument_context:new(), prop_spawn_key, prop_spawn_value),
  ok = instrument_context:set_current(Ctx),

  %% Test spawn/2
  Pid1 = instrument_propagation:spawn(fun(Arg) ->
    %% Should have the context
    prop_spawn_value = instrument_context:get_value(instrument_context:current(), prop_spawn_key),
    %% Verify arg was passed
    test_arg = Arg,
    %% Should not have extra context history entries (uses set_current, not attach)
    Count = count_context_entries(),
    Parent ! {self(), spawn2_count, Count}
  end, [test_arg]),

  receive
    {Pid1, spawn2_count, Count1} ->
      %% Should have at most 1 entry (the main context key, no history tokens)
      true = Count1 =< 1
  after 1000 ->
    ct:fail(spawn2_timeout)
  end,

  %% Test spawn_link/2
  Pid2 = instrument_propagation:spawn_link(fun(Arg) ->
    prop_spawn_value = instrument_context:get_value(instrument_context:current(), prop_spawn_key),
    test_arg = Arg,
    Count = count_context_entries(),
    Parent ! {self(), spawn_link2_count, Count}
  end, [test_arg]),

  receive
    {Pid2, spawn_link2_count, Count2} ->
      true = Count2 =< 1
  after 1000 ->
    ct:fail(spawn_link2_timeout)
  end,

  %% Test spawn_monitor/1
  {Pid3, _MonRef} = instrument_propagation:spawn_monitor(fun() ->
    prop_spawn_value = instrument_context:get_value(instrument_context:current(), prop_spawn_key),
    Count = count_context_entries(),
    Parent ! {self(), spawn_monitor_count, Count}
  end),

  receive
    {Pid3, spawn_monitor_count, Count3} ->
      true = Count3 =< 1
  after 1000 ->
    ct:fail(spawn_monitor_timeout)
  end,

  %% Test spawn_opt/2
  Pid4 = instrument_propagation:spawn_opt(fun() ->
    prop_spawn_value = instrument_context:get_value(instrument_context:current(), prop_spawn_key),
    Count = count_context_entries(),
    Parent ! {self(), spawn_opt_count, Count}
  end, []),

  receive
    {Pid4, spawn_opt_count, Count4} ->
      true = Count4 =< 1
  after 1000 ->
    ct:fail(spawn_opt_timeout)
  end,

  ok.

count_context_entries() ->
  Dict = erlang:get(),
  length([K || {K, _} <- Dict, is_context_key(K)]).

is_context_key('$instrument_context') -> true;
is_context_key({'$instrument_context', _}) -> true;
is_context_key(_) -> false.

%% ============================================================================
%% Baggage Tests
%% ============================================================================

baggage_operations(_Config) ->
  %% Set and get
  ok = instrument_baggage:set(user_id, <<"123">>),
  <<"123">> = instrument_baggage:get(user_id),

  %% Get with default
  default_val = instrument_baggage:get(missing, default_val),

  %% Get all
  All = instrument_baggage:get_all(),
  true = maps:is_key(<<"user_id">>, All),

  %% Remove
  ok = instrument_baggage:remove(user_id),
  undefined = instrument_baggage:get(user_id),

  %% Clear
  ok = instrument_baggage:set(key1, val1),
  ok = instrument_baggage:set(key2, val2),
  ok = instrument_baggage:clear(),
  #{} = instrument_baggage:get_all(),
  ok.

baggage_encode_decode(_Config) ->
  %% Create baggage
  Baggage = #{
    <<"key1">> => {<<"value1">>, #{}},
    <<"key2">> => {<<"value 2">>, #{}}
  },

  %% Encode
  Encoded = instrument_baggage:encode(Baggage),
  true = is_binary(Encoded),

  %% Decode
  Decoded = instrument_baggage:decode(Encoded),
  {<<"value1">>, _} = maps:get(<<"key1">>, Decoded),
  ok.

%% ============================================================================
%% Propagation Tests
%% ============================================================================

propagation_spawn(_Config) ->
  Parent = self(),

  %% Set up some context
  Ctx = instrument_context:set_value(instrument_context:new(), prop_key, prop_value),
  _ = instrument_context:attach(Ctx),

  %% Spawn with propagation
  Pid = instrument_propagation:spawn(fun() ->
    Current = instrument_context:current(),
    Value = instrument_context:get_value(Current, prop_key),
    Parent ! {self(), Value}
  end),

  receive
    {Pid, prop_value} -> ok
  after 1000 ->
    ct:fail(timeout)
  end.

propagation_inject_extract(_Config) ->
  %% Start a span to have trace context
  _Span = instrument_tracer:start_span(<<"test_span">>),

  %% Set baggage
  ok = instrument_baggage:set(request_id, <<"req-123">>),

  %% Inject into carrier
  Carrier = instrument_propagation:inject(#{}),

  %% Should have traceparent header
  true = maps:is_key(<<"traceparent">>, Carrier),

  %% Should have baggage header
  true = maps:is_key(<<"baggage">>, Carrier),

  %% Extract into new context
  Ctx = instrument_propagation:extract(Carrier),

  %% Should have span_ctx
  SpanCtx = instrument_context:get_value(Ctx, span_ctx),
  true = SpanCtx =/= undefined,

  %% Clean up
  instrument_tracer:end_span(),
  ok.
