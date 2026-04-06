%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_resource_SUITE).
-author("benoitc").

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("instrument_otel.hrl").

-export([
  all/0,
  init_per_suite/1,
  end_per_suite/1,
  init_per_testcase/2,
  end_per_testcase/2
]).

-export([
  create_resource_test/1,
  empty_resource_test/1,
  merge_resources_test/1,
  default_resource_test/1,
  env_detector_test/1,
  process_detector_test/1,
  host_detector_test/1,
  custom_detector_test/1,
  detect_all_test/1,
  set_get_default_test/1,
  service_detector_atom_keys_test/1,
  service_detector_precedence_test/1
]).

all() ->
  [
    create_resource_test,
    empty_resource_test,
    merge_resources_test,
    default_resource_test,
    env_detector_test,
    process_detector_test,
    host_detector_test,
    custom_detector_test,
    detect_all_test,
    set_get_default_test,
    service_detector_atom_keys_test,
    service_detector_precedence_test
  ].

init_per_suite(Config) ->
  _ = application:ensure_all_started(crypto),
  ok = application:start(instrument),
  Config.

end_per_suite(_Config) ->
  ok = application:stop(instrument),
  ok.

init_per_testcase(_TestCase, Config) ->
  Config.

end_per_testcase(_TestCase, _Config) ->
  %% Clean up any registered detectors
  ok.

%% ============================================================================
%% Test Cases
%% ============================================================================

create_resource_test(_Config) ->
  Attrs = #{
    <<"service.name">> => <<"test-service">>,
    <<"service.version">> => <<"1.0.0">>
  },
  Resource = instrument_resource:create(Attrs),

  ?assertEqual(Attrs, instrument_resource:get_attributes(Resource)),
  ?assertEqual(undefined, instrument_resource:get_schema_url(Resource)),

  %% With schema URL
  Resource2 = instrument_resource:create(Attrs, <<"https://opentelemetry.io/schemas/1.0.0">>),
  ?assertEqual(<<"https://opentelemetry.io/schemas/1.0.0">>, instrument_resource:get_schema_url(Resource2)),
  ok.

empty_resource_test(_Config) ->
  Resource = instrument_resource:empty(),
  ?assertEqual(#{}, instrument_resource:get_attributes(Resource)),
  ?assertEqual(undefined, instrument_resource:get_schema_url(Resource)),
  ok.

merge_resources_test(_Config) ->
  R1 = instrument_resource:create(#{
    <<"key1">> => <<"value1">>,
    <<"key2">> => <<"old_value">>
  }),
  R2 = instrument_resource:create(#{
    <<"key2">> => <<"new_value">>,
    <<"key3">> => <<"value3">>
  }),

  Merged = instrument_resource:merge(R1, R2),
  Attrs = instrument_resource:get_attributes(Merged),

  ?assertEqual(<<"value1">>, maps:get(<<"key1">>, Attrs)),
  ?assertEqual(<<"new_value">>, maps:get(<<"key2">>, Attrs)),
  ?assertEqual(<<"value3">>, maps:get(<<"key3">>, Attrs)),

  %% Schema URL merging
  R3 = instrument_resource:create(#{}, <<"schema1">>),
  R4 = instrument_resource:create(#{}, <<"schema2">>),
  Merged2 = instrument_resource:merge(R3, R4),
  ?assertEqual(<<"schema2">>, instrument_resource:get_schema_url(Merged2)),

  %% Later undefined doesn't override
  R5 = instrument_resource:create(#{}, undefined),
  Merged3 = instrument_resource:merge(R3, R5),
  ?assertEqual(<<"schema1">>, instrument_resource:get_schema_url(Merged3)),
  ok.

default_resource_test(_Config) ->
  Resource = instrument_resource:default(),
  Attrs = instrument_resource:get_attributes(Resource),

  %% Should have SDK attributes
  ?assertEqual(<<"instrument">>, maps:get(<<"telemetry.sdk.name">>, Attrs)),
  ?assertEqual(<<"erlang">>, maps:get(<<"telemetry.sdk.language">>, Attrs)),
  ?assert(maps:is_key(<<"telemetry.sdk.version">>, Attrs)),

  %% Should have process attributes
  ?assert(maps:is_key(<<"process.runtime.name">>, Attrs)),
  ?assert(maps:is_key(<<"process.runtime.version">>, Attrs)),

  %% Should have host attributes
  ?assert(maps:is_key(<<"host.name">>, Attrs)),
  ok.

env_detector_test(_Config) ->
  %% Set environment variable
  os:putenv("OTEL_RESOURCE_ATTRIBUTES", "service.name=env-service,env.key=env-value"),

  Resource = instrument_resource_detector:detect_env(),
  Attrs = instrument_resource:get_attributes(Resource),

  ?assertEqual(<<"env-service">>, maps:get(<<"service.name">>, Attrs)),
  ?assertEqual(<<"env-value">>, maps:get(<<"env.key">>, Attrs)),

  %% Clean up
  os:unsetenv("OTEL_RESOURCE_ATTRIBUTES"),

  %% Empty when not set
  EmptyResource = instrument_resource_detector:detect_env(),
  ?assertEqual(#{}, instrument_resource:get_attributes(EmptyResource)),
  ok.

process_detector_test(_Config) ->
  Resource = instrument_resource_detector:detect_process(),
  Attrs = instrument_resource:get_attributes(Resource),

  ?assertEqual(<<"BEAM">>, maps:get(<<"process.runtime.name">>, Attrs)),
  ?assert(maps:is_key(<<"process.runtime.version">>, Attrs)),
  ?assert(maps:is_key(<<"process.runtime.description">>, Attrs)),
  ?assert(maps:is_key(<<"process.pid">>, Attrs)),
  ok.

host_detector_test(_Config) ->
  Resource = instrument_resource_detector:detect_host(),
  Attrs = instrument_resource:get_attributes(Resource),

  ?assert(maps:is_key(<<"host.name">>, Attrs)),
  ?assert(maps:is_key(<<"host.arch">>, Attrs)),
  ?assert(maps:is_key(<<"os.type">>, Attrs)),
  ok.

custom_detector_test(_Config) ->
  %% Register a custom detector
  ok = instrument_resource_detector:register(custom_test, fun() ->
    instrument_resource:create(#{<<"custom.attr">> => <<"custom-value">>})
  end),

  ?assert(lists:member(custom_test, instrument_resource_detector:list())),

  %% Detect with custom detector
  Resource = instrument_resource_detector:detect(custom_test),
  Attrs = instrument_resource:get_attributes(Resource),
  ?assertEqual(<<"custom-value">>, maps:get(<<"custom.attr">>, Attrs)),

  %% Unregister
  ok = instrument_resource_detector:unregister(custom_test),
  ?assertNot(lists:member(custom_test, instrument_resource_detector:list())),
  ok.

detect_all_test(_Config) ->
  %% Register a test detector
  ok = instrument_resource_detector:register(test_detector, fun() ->
    instrument_resource:create(#{<<"test.detector">> => <<"active">>})
  end),

  Resource = instrument_resource_detector:detect_all(),
  Attrs = instrument_resource:get_attributes(Resource),

  %% Should have env, process, host, and custom detector attributes
  ?assert(maps:is_key(<<"process.runtime.name">>, Attrs)),
  ?assert(maps:is_key(<<"host.name">>, Attrs)),
  ?assertEqual(<<"active">>, maps:get(<<"test.detector">>, Attrs)),

  %% Clean up
  ok = instrument_resource_detector:unregister(test_detector),
  ok.

set_get_default_test(_Config) ->
  %% Create and set a custom default
  CustomResource = instrument_resource:create(#{
    <<"service.name">> => <<"custom-default-service">>
  }),
  ok = instrument_resource:set_default(CustomResource),

  Retrieved = instrument_resource:get_default(),
  Attrs = instrument_resource:get_attributes(Retrieved),
  ?assertEqual(<<"custom-default-service">>, maps:get(<<"service.name">>, Attrs)),
  ok.

%% Test that service detector converts atom keys to OTEL binary attribute names (P2 fix)
service_detector_atom_keys_test(_Config) ->
  %% Set app config with atom keys
  application:set_env(instrument, resource, #{
    service_name => <<"my-service">>,
    service_version => <<"1.2.3">>,
    service_namespace => <<"production">>,
    service_instance_id => <<"instance-1">>,
    custom_attr => <<"custom-value">>
  }),

  Resource = instrument_resource_detector:detect_service(),
  Attrs = instrument_resource:get_attributes(Resource),

  %% Verify atom keys were converted to OTEL binary keys
  ?assertEqual(<<"my-service">>, maps:get(<<"service.name">>, Attrs)),
  ?assertEqual(<<"1.2.3">>, maps:get(<<"service.version">>, Attrs)),
  ?assertEqual(<<"production">>, maps:get(<<"service.namespace">>, Attrs)),
  ?assertEqual(<<"instance-1">>, maps:get(<<"service.instance.id">>, Attrs)),
  %% Custom attrs should also be converted to binary keys
  ?assertEqual(<<"custom-value">>, maps:get(<<"custom_attr">>, Attrs)),

  %% Verify old atom keys are NOT present
  ?assertEqual(error, maps:find(service_name, Attrs)),
  ?assertEqual(error, maps:find(service_version, Attrs)),

  %% Clean up
  application:unset_env(instrument, resource),
  ok.

%% Test that OTEL_SERVICE_NAME takes precedence over OTEL_RESOURCE_ATTRIBUTES (P3 fix)
service_detector_precedence_test(_Config) ->
  %% Stop app so we can set env vars before it reads them
  ok = application:stop(instrument),

  %% Set both env vars with conflicting service.name values
  os:putenv("OTEL_SERVICE_NAME", "from-service-name-env"),
  os:putenv("OTEL_RESOURCE_ATTRIBUTES", "service.name=from-resource-attrs,other.key=other-value"),

  %% Restart app to pick up env vars
  ok = application:start(instrument),

  %% Detect all resources - service detector should run after env detector
  Resource = instrument_resource_detector:detect_all(),
  Attrs = instrument_resource:get_attributes(Resource),

  %% OTEL_SERVICE_NAME should win (service detector runs last)
  ?assertEqual(<<"from-service-name-env">>, maps:get(<<"service.name">>, Attrs)),
  %% Other attributes from OTEL_RESOURCE_ATTRIBUTES should still be present
  ?assertEqual(<<"other-value">>, maps:get(<<"other.key">>, Attrs)),

  %% Clean up
  os:unsetenv("OTEL_SERVICE_NAME"),
  os:unsetenv("OTEL_RESOURCE_ATTRIBUTES"),
  ok.
