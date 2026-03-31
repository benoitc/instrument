%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_exporter_SUITE).
-author("benoitc").

-export([
  all/0,
  init_per_suite/1,
  end_per_suite/1,
  init_per_testcase/2,
  end_per_testcase/2
]).

-export([
  register_unregister/1,
  console_exporter_text/1,
  console_exporter_json/1,
  flush/1
]).

-include("instrument_otel.hrl").

all() ->
  [
    register_unregister,
    console_exporter_text,
    console_exporter_json,
    flush
  ].

init_per_suite(Config) ->
  _ = application:ensure_all_started(crypto),
  ok = application:start(instrument),
  Config.

end_per_suite(Config) ->
  ok = application:stop(instrument),
  Config.

init_per_testcase(_, Config) ->
  %% Clean up context between tests
  erlang:erase('$instrument_context'),
  %% Unregister all exporters
  lists:foreach(fun(M) ->
    instrument_exporter:unregister(M)
  end, instrument_exporter:list()),
  Config.

end_per_testcase(_, _Config) ->
  erlang:erase('$instrument_context'),
  ok.

%% ============================================================================
%% Tests
%% ============================================================================

register_unregister(_Config) ->
  %% Initially no exporters (besides any auto-registered)
  Initial = instrument_exporter:list(),

  %% Register console exporter
  ok = instrument_exporter:register(instrument_exporter_console:new()),
  true = lists:member(instrument_exporter_console, instrument_exporter:list()),

  %% Unregister
  ok = instrument_exporter:unregister(instrument_exporter_console),
  false = lists:member(instrument_exporter_console, instrument_exporter:list()),

  %% Should be back to initial state
  Initial = instrument_exporter:list(),
  ok.

console_exporter_text(_Config) ->
  %% Register console exporter with text format
  ok = instrument_exporter:register(instrument_exporter_console:new(#{
    format => text,
    output => standard_io
  })),

  %% Create a span that will be exported
  instrument_tracer:with_span(<<"test_span">>, fun() ->
    instrument_tracer:set_attributes(#{<<"key">> => <<"value">>}),
    instrument_tracer:add_event(<<"test_event">>),
    instrument_tracer:set_status(ok)
  end),

  %% Flush to ensure export
  ok = instrument_exporter:flush(),
  ok.

console_exporter_json(_Config) ->
  %% Register console exporter with JSON format
  ok = instrument_exporter:register(instrument_exporter_console:new(#{
    format => json,
    output => standard_io
  })),

  %% Create a span that will be exported
  instrument_tracer:with_span(<<"json_span">>, fun() ->
    instrument_tracer:set_attributes(#{
      <<"string">> => <<"value">>,
      <<"int">> => 42,
      <<"float">> => 3.14,
      <<"bool">> => true
    }),
    instrument_tracer:set_status(ok)
  end),

  %% Flush to ensure export
  ok = instrument_exporter:flush(),
  ok.

flush(_Config) ->
  %% Test flush with no exporters
  ok = instrument_exporter:flush(),

  %% Register console exporter
  ok = instrument_exporter:register(instrument_exporter_console:new()),

  %% Create span and flush
  instrument_tracer:with_span(<<"flush_test">>, fun() -> ok end),
  ok = instrument_exporter:flush(),

  %% Shutdown
  ok = instrument_exporter:shutdown(),
  [] = instrument_exporter:list(),
  ok.
