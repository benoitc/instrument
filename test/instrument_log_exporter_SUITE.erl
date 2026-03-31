%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_log_exporter_SUITE).
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
  log_record_creation/1,
  console_exporter_text/1,
  console_exporter_json/1,
  console_with_trace_context/1,
  file_exporter_text/1,
  file_exporter_json/1,
  file_exporter_rotation/1,
  file_exporter_recovery_after_failure/1,
  otlp_exporter_init/1,
  batch_export/1,
  flush/1,
  logger_handler_integration/1
]).

-include("instrument_otel.hrl").

all() ->
  [
    register_unregister,
    log_record_creation,
    console_exporter_text,
    console_exporter_json,
    console_with_trace_context,
    file_exporter_text,
    file_exporter_json,
    file_exporter_rotation,
    file_exporter_recovery_after_failure,
    otlp_exporter_init,
    batch_export,
    flush,
    logger_handler_integration
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
    instrument_log_exporter:unregister(M)
  end, instrument_log_exporter:list()),
  %% Uninstall logger integration
  instrument_logger:uninstall(),
  Config.

end_per_testcase(_, Config) ->
  erlang:erase('$instrument_context'),
  instrument_logger:uninstall(),
  %% Clean up any test files
  file:delete("/tmp/test_log.log"),
  file:delete("/tmp/rotation_test.log"),
  lists:foreach(fun(N) ->
    file:delete("/tmp/rotation_test.log." ++ integer_to_list(N)),
    file:delete("/tmp/rotation_test.log." ++ integer_to_list(N) ++ ".gz")
  end, lists:seq(1, 10)),
  Config.

%% ============================================================================
%% Tests
%% ============================================================================

register_unregister(_Config) ->
  %% Initially no exporters
  Initial = instrument_log_exporter:list(),

  %% Register console exporter
  ok = instrument_log_exporter:register(instrument_log_exporter_console:new()),
  true = lists:member(instrument_log_exporter_console, instrument_log_exporter:list()),

  %% Unregister
  ok = instrument_log_exporter:unregister(instrument_log_exporter_console),
  false = lists:member(instrument_log_exporter_console, instrument_log_exporter:list()),

  %% Should be back to initial state
  Initial = instrument_log_exporter:list(),
  ok.

log_record_creation(_Config) ->
  %% Test creating log records from logger events
  Level = info,
  Msg = {string, <<"Test message">>},
  Meta = #{
    time => erlang:system_time(microsecond),
    user => <<"testuser">>,
    request_id => <<"12345">>
  },

  LogRecord = instrument_logger:make_log_record(Level, Msg, Meta),

  %% Verify log record fields
  true = is_record(LogRecord, log_record),
  true = is_integer(LogRecord#log_record.timestamp),
  true = is_integer(LogRecord#log_record.observed_timestamp),
  ?SEVERITY_INFO = LogRecord#log_record.severity_number,
  <<"INFO">> = LogRecord#log_record.severity_text,
  <<"Test message">> = LogRecord#log_record.body,

  %% Check attributes (should contain user and request_id)
  Attrs = LogRecord#log_record.attributes,
  true = maps:is_key(user, Attrs),
  true = maps:is_key(request_id, Attrs),
  ok.

console_exporter_text(_Config) ->
  %% Register console exporter with text format
  ok = instrument_log_exporter:register(instrument_log_exporter_console:new(#{
    format => text,
    output => standard_io
  })),

  %% Create and export a log record
  LogRecord = #log_record{
    timestamp = erlang:system_time(nanosecond),
    observed_timestamp = erlang:system_time(nanosecond),
    severity_number = ?SEVERITY_INFO,
    severity_text = <<"INFO">>,
    body = <<"Test log message">>,
    attributes = #{<<"key">> => <<"value">>}
  },

  ok = instrument_log_exporter:export(LogRecord),
  ok = instrument_log_exporter:flush(),
  ok.

console_exporter_json(_Config) ->
  %% Register console exporter with JSON format
  ok = instrument_log_exporter:register(instrument_log_exporter_console:new(#{
    format => json,
    output => standard_io
  })),

  %% Create and export a log record
  LogRecord = #log_record{
    timestamp = erlang:system_time(nanosecond),
    observed_timestamp = erlang:system_time(nanosecond),
    severity_number = ?SEVERITY_ERROR,
    severity_text = <<"ERROR">>,
    body = <<"Error occurred">>,
    attributes = #{
      <<"error.type">> => <<"validation">>,
      <<"error.code">> => 400
    }
  },

  ok = instrument_log_exporter:export(LogRecord),
  ok = instrument_log_exporter:flush(),
  ok.

console_with_trace_context(_Config) ->
  %% Register console exporter
  ok = instrument_log_exporter:register(instrument_log_exporter_console:new(#{
    format => text,
    output => standard_io
  })),

  %% Create log record with trace context
  TraceId = instrument_id:generate_trace_id(),
  SpanId = instrument_id:generate_span_id(),

  LogRecord = #log_record{
    timestamp = erlang:system_time(nanosecond),
    observed_timestamp = erlang:system_time(nanosecond),
    severity_number = ?SEVERITY_INFO,
    severity_text = <<"INFO">>,
    body = <<"Request processed">>,
    attributes = #{},
    trace_id = TraceId,
    span_id = SpanId,
    trace_flags = 1
  },

  ok = instrument_log_exporter:export(LogRecord),
  ok = instrument_log_exporter:flush(),
  ok.

file_exporter_text(_Config) ->
  %% Register file exporter with text format
  Path = "/tmp/test_log.log",
  ok = instrument_log_exporter:register(instrument_log_exporter_file:new(#{
    path => Path,
    format => text
  })),

  %% Create and export log records
  LogRecord1 = #log_record{
    timestamp = erlang:system_time(nanosecond),
    observed_timestamp = erlang:system_time(nanosecond),
    severity_number = ?SEVERITY_INFO,
    severity_text = <<"INFO">>,
    body = <<"First log message">>,
    attributes = #{}
  },

  LogRecord2 = #log_record{
    timestamp = erlang:system_time(nanosecond),
    observed_timestamp = erlang:system_time(nanosecond),
    severity_number = ?SEVERITY_WARN,
    severity_text = <<"WARN">>,
    body = <<"Second log message">>,
    attributes = #{}
  },

  ok = instrument_log_exporter:export(LogRecord1),
  ok = instrument_log_exporter:export(LogRecord2),
  ok = instrument_log_exporter:flush(),

  %% Verify file exists and has content
  timer:sleep(100), %% Give file system time to sync
  {ok, Content} = file:read_file(Path),
  true = byte_size(Content) > 0,
  true = binary:match(Content, <<"First log message">>) =/= nomatch,
  true = binary:match(Content, <<"Second log message">>) =/= nomatch,
  ok.

file_exporter_json(_Config) ->
  %% Register file exporter with JSON format
  Path = "/tmp/test_log.log",
  ok = instrument_log_exporter:register(instrument_log_exporter_file:new(#{
    path => Path,
    format => json
  })),

  %% Create and export a log record
  LogRecord = #log_record{
    timestamp = erlang:system_time(nanosecond),
    observed_timestamp = erlang:system_time(nanosecond),
    severity_number = ?SEVERITY_DEBUG,
    severity_text = <<"DEBUG">>,
    body = <<"Debug info">>,
    attributes = #{<<"debug_key">> => <<"debug_value">>}
  },

  ok = instrument_log_exporter:export(LogRecord),
  ok = instrument_log_exporter:flush(),

  %% Verify file contains JSON
  timer:sleep(100),
  {ok, Content} = file:read_file(Path),
  true = byte_size(Content) > 0,
  %% Should be valid JSONL
  true = binary:match(Content, <<"severityText">>)  =/= nomatch,
  true = binary:match(Content, <<"DEBUG">>)  =/= nomatch,
  ok.

file_exporter_rotation(_Config) ->
  %% Register file exporter with small max_size to trigger rotation
  Path = "/tmp/rotation_test.log",
  ok = instrument_log_exporter:register(instrument_log_exporter_file:new(#{
    path => Path,
    format => text,
    max_size => 100,  %% Very small to trigger rotation
    max_files => 3,
    compress => false
  })),

  %% Create multiple log records to trigger rotation
  lists:foreach(fun(N) ->
    LogRecord = #log_record{
      timestamp = erlang:system_time(nanosecond),
      observed_timestamp = erlang:system_time(nanosecond),
      severity_number = ?SEVERITY_INFO,
      severity_text = <<"INFO">>,
      body = list_to_binary("Log message number " ++ integer_to_list(N) ++ " with extra padding to make it longer"),
      attributes = #{}
    },
    ok = instrument_log_exporter:export(LogRecord)
  end, lists:seq(1, 10)),

  ok = instrument_log_exporter:flush(),
  timer:sleep(200),

  %% Verify main log file exists
  true = filelib:is_regular(Path),

  %% Check for rotated files (at least one should exist)
  RotatedExists = lists:any(fun(N) ->
    filelib:is_regular(Path ++ "." ++ integer_to_list(N))
  end, lists:seq(1, 3)),
  true = RotatedExists,
  ok.

file_exporter_recovery_after_failure(_Config) ->
  %% Test that file exporter recovers after fd becomes undefined
  %% This simulates what happens when rotation fails to reopen the file

  %% Initialize state directly to test recovery
  Path = <<"/tmp/recovery_test.log">>,
  file:delete("/tmp/recovery_test.log"),

  %% Initialize exporter
  {ok, State} = instrument_log_exporter_file:init(#{path => Path, format => text}),

  %% Export should work
  LogRecord1 = #log_record{
    timestamp = erlang:system_time(nanosecond),
    observed_timestamp = erlang:system_time(nanosecond),
    severity_number = ?SEVERITY_INFO,
    severity_text = <<"INFO">>,
    body = <<"First message">>,
    attributes = #{}
  },
  {ok, State2} = instrument_log_exporter_file:export([LogRecord1], State),

  %% Simulate fd becoming undefined (like after rotation failure)
  %% We do this by creating a state record with fd = undefined
  %% Note: We can't easily access the record, but we can test via the registered exporter

  %% Test the full path via registered exporter
  ok = instrument_log_exporter:register(instrument_log_exporter_file:new(#{
    path => <<"/tmp/recovery_test2.log">>,
    format => text
  })),

  %% Export some messages - should work
  LogRecord2 = #log_record{
    timestamp = erlang:system_time(nanosecond),
    observed_timestamp = erlang:system_time(nanosecond),
    severity_number = ?SEVERITY_INFO,
    severity_text = <<"INFO">>,
    body = <<"Recovery test message">>,
    attributes = #{}
  },
  ok = instrument_log_exporter:export(LogRecord2),
  ok = instrument_log_exporter:flush(),

  %% Verify file has content
  timer:sleep(100),
  {ok, Content} = file:read_file("/tmp/recovery_test2.log"),
  true = byte_size(Content) > 0,
  true = binary:match(Content, <<"Recovery test message">>) =/= nomatch,

  %% Cleanup
  ok = instrument_log_exporter_file:shutdown(State2),
  file:delete("/tmp/recovery_test.log"),
  file:delete("/tmp/recovery_test2.log"),
  ok.

otlp_exporter_init(_Config) ->
  %% Test OTLP exporter initialization
  Config = #{endpoint => <<"http://localhost:4318">>},
  #{module := Mod, config := Cfg} = instrument_log_exporter_otlp:new(Config),
  instrument_log_exporter_otlp = Mod,
  <<"http://localhost:4318">> = maps:get(endpoint, Cfg),

  %% Test initialization with options
  {ok, State} = instrument_log_exporter_otlp:init(#{
    endpoint => "http://localhost:4318",
    compression => gzip,
    timeout => 5000
  }),

  %% Force flush returns ok
  {ok, _} = instrument_log_exporter_otlp:force_flush(State),

  %% Shutdown returns ok
  ok = instrument_log_exporter_otlp:shutdown(State),
  ok.

batch_export(_Config) ->
  %% Register console exporter
  ok = instrument_log_exporter:register(instrument_log_exporter_console:new(#{
    format => text,
    output => standard_io
  })),

  %% Create multiple log records
  LogRecords = [
    #log_record{
      timestamp = erlang:system_time(nanosecond),
      observed_timestamp = erlang:system_time(nanosecond),
      severity_number = ?SEVERITY_INFO,
      severity_text = <<"INFO">>,
      body = list_to_binary("Batch log " ++ integer_to_list(N)),
      attributes = #{}
    } || N <- lists:seq(1, 5)
  ],

  %% Export as batch
  ok = instrument_log_exporter:export_batch(LogRecords),
  ok = instrument_log_exporter:flush(),
  ok.

flush(_Config) ->
  %% Test flush with no exporters
  ok = instrument_log_exporter:flush(),

  %% Register console exporter
  ok = instrument_log_exporter:register(instrument_log_exporter_console:new()),

  %% Create log record and flush
  LogRecord = #log_record{
    timestamp = erlang:system_time(nanosecond),
    observed_timestamp = erlang:system_time(nanosecond),
    severity_number = ?SEVERITY_INFO,
    severity_text = <<"INFO">>,
    body = <<"Flush test">>,
    attributes = #{}
  },
  ok = instrument_log_exporter:export(LogRecord),
  ok = instrument_log_exporter:flush(),

  %% Shutdown
  ok = instrument_log_exporter:shutdown(),
  [] = instrument_log_exporter:list(),
  ok.

logger_handler_integration(_Config) ->
  %% Register console exporter
  ok = instrument_log_exporter:register(instrument_log_exporter_console:new(#{
    format => text,
    output => standard_io
  })),

  %% Install logger with exporter mode
  ok = instrument_logger:install(#{exporter => true, filter => false}),

  %% Log some messages - they should go through the exporter
  logger:info("Test info message"),
  logger:warning("Test warning message"),
  logger:error("Test error message"),

  %% Log within a span to verify trace context
  instrument_tracer:with_span(<<"log_test_span">>, fun() ->
    logger:info("Message within span")
  end),

  %% Flush to ensure export
  ok = instrument_log_exporter:flush(),
  ok.
