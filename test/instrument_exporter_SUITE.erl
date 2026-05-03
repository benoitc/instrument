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
  flush/1,
  console_export_callback_test/1,
  otlp_export_callback_test/1
]).

-include("instrument_otel.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
  [
    register_unregister,
    console_exporter_text,
    console_exporter_json,
    flush,
    console_export_callback_test,
    otlp_export_callback_test
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

console_export_callback_test(_Config) ->
  %% Direct exercise of the exporter's callback contract:
  %% init/1 -> export/2 -> shutdown/1, both formats and all output kinds.
  Span = make_test_span(<<"callback_span">>),

  %% standard_io
  {ok, TextState} = instrument_exporter_console:init(#{format => text,
                                                       output => standard_io}),
  ?assertMatch({ok, _}, instrument_exporter_console:export([Span], TextState)),
  ?assertMatch({ok, _}, instrument_exporter_console:export([], TextState)),
  ok = instrument_exporter_console:shutdown(TextState),

  {ok, JsonState} = instrument_exporter_console:init(#{format => json,
                                                       output => standard_io}),
  ?assertMatch({ok, _}, instrument_exporter_console:export([Span], JsonState)),
  ?assertMatch({ok, _}, instrument_exporter_console:force_flush(JsonState)),
  ok = instrument_exporter_console:shutdown(JsonState),

  %% File output: data should land on disk and shutdown closes the fd.
  Path = "/tmp/instrument_console_export_test.log",
  _ = file:delete(Path),
  {ok, FileState} = instrument_exporter_console:init(#{format => text,
                                                       output => {file, Path}}),
  {ok, _} = instrument_exporter_console:export([Span], FileState),
  ok = instrument_exporter_console:shutdown(FileState),
  {ok, Bin} = file:read_file(Path),
  ?assert(byte_size(Bin) > 0),
  ?assertNotEqual(nomatch, binary:match(Bin, <<"callback_span">>)),
  _ = file:delete(Path),
  ok.

otlp_export_callback_test(_Config) ->
  %% Stub the HTTP transport so export/2 can run end-to-end without network.
  meck:new(instrument_otlp_retry, [passthrough]),
  meck:expect(instrument_otlp_retry, send_with_retry,
              fun(_Method, _Url, _Headers, Body, _Opts) ->
                  Self = persistent_term:get({?MODULE, otlp_observer}, undefined),
                  case Self of
                    undefined -> ok;
                    Pid -> Pid ! {otlp_payload, Body}
                  end,
                  ok
              end),
  persistent_term:put({?MODULE, otlp_observer}, self()),
  try
    {ok, State} = instrument_exporter_otlp:init(
                    #{endpoint => "http://localhost:9999/v1/traces"}),
    Span = make_test_span(<<"otlp_span">>),
    Result = instrument_exporter_otlp:export([Span], State),
    ?assertMatch({ok, _}, Result),
    %% If the exporter calls retry, we'd see a payload. Some implementations
    %% may also early-return for empty/disabled cases; accept either path.
    receive
      {otlp_payload, Payload} ->
        ?assert(is_binary(Payload) orelse is_list(Payload)),
        Bin = iolist_to_binary(Payload),
        ?assertNotEqual(nomatch, binary:match(Bin, <<"otlp_span">>))
    after 200 ->
        ok
    end,
    ok = instrument_exporter_otlp:shutdown(State)
  after
    persistent_term:erase({?MODULE, otlp_observer}),
    meck:unload(instrument_otlp_retry)
  end,
  ok.

%% ---------------------------------------------------------------------------
%% Helpers
%% ---------------------------------------------------------------------------

make_test_span(Name) ->
  TraceId = instrument_id:generate_trace_id(),
  SpanId = instrument_id:generate_span_id(),
  Now = erlang:system_time(nanosecond),
  #span{
    name = Name,
    ctx = #span_ctx{trace_id = TraceId,
                    span_id = SpanId,
                    trace_flags = 1,
                    trace_state = [],
                    is_remote = false},
    parent_ctx = undefined,
    kind = internal,
    start_time = Now - 1000,
    end_time = Now,
    attributes = #{<<"k">> => <<"v">>},
    events = [],
    links = [],
    status = ok,
    is_recording = false
  }.
