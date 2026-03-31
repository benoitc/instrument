%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc OpenTelemetry Resource representation.
%%
%% A Resource describes the entity producing telemetry. It contains
%% attributes that identify the service, host, process, etc.
%%
%% == Example Usage ==
%% ```
%% %% Create a resource
%% Resource = instrument_resource:create(#{
%%   <<"service.name">> => <<"my-service">>,
%%   <<"service.version">> => <<"1.0.0">>
%% }).
%%
%% %% Merge resources (later values override)
%% Merged = instrument_resource:merge(Resource1, Resource2).
%%
%% %% Get the default resource (with detectors)
%% Default = instrument_resource:default().
%% '''
-module(instrument_resource).
-author("benoitc").

-include("instrument_otel.hrl").

%% API
-export([
  create/1,
  create/2,
  empty/0,
  default/0,
  merge/2,
  get_attributes/1,
  get_schema_url/1,
  set_default/1,
  get_default/0
]).

-define(DEFAULT_RESOURCE_KEY, '$instrument_default_resource').

%% Semantic convention attribute keys
-define(SERVICE_NAME, <<"service.name">>).
-define(SERVICE_VERSION, <<"service.version">>).
-define(SERVICE_INSTANCE_ID, <<"service.instance.id">>).
-define(TELEMETRY_SDK_NAME, <<"telemetry.sdk.name">>).
-define(TELEMETRY_SDK_LANGUAGE, <<"telemetry.sdk.language">>).
-define(TELEMETRY_SDK_VERSION, <<"telemetry.sdk.version">>).

%% ============================================================================
%% API
%% ============================================================================

%% @doc Creates a resource with the given attributes.
-spec create(map()) -> #resource{}.
create(Attributes) when is_map(Attributes) ->
  create(Attributes, undefined).

%% @doc Creates a resource with attributes and schema URL.
-spec create(map(), binary() | undefined) -> #resource{}.
create(Attributes, SchemaUrl) when is_map(Attributes) ->
  #resource{
    attributes = Attributes,
    schema_url = SchemaUrl
  }.

%% @doc Creates an empty resource.
-spec empty() -> #resource{}.
empty() ->
  #resource{
    attributes = #{},
    schema_url = undefined
  }.

%% @doc Creates a default resource with SDK and detected attributes.
-spec default() -> #resource{}.
default() ->
  %% Start with SDK attributes
  SdkResource = create(#{
    ?TELEMETRY_SDK_NAME => <<"instrument">>,
    ?TELEMETRY_SDK_LANGUAGE => <<"erlang">>,
    ?TELEMETRY_SDK_VERSION => <<"0.3.0">>
  }),

  %% Run all registered detectors
  DetectedResource = instrument_resource_detector:detect_all(),

  %% Merge: SDK first, then detected (detected can override)
  merge(SdkResource, DetectedResource).

%% @doc Merges two resources. Later resource attributes override earlier ones.
-spec merge(#resource{}, #resource{}) -> #resource{}.
merge(#resource{attributes = Attrs1, schema_url = Schema1},
      #resource{attributes = Attrs2, schema_url = Schema2}) ->
  %% Later attributes override earlier ones
  MergedAttrs = maps:merge(Attrs1, Attrs2),
  %% Use later schema URL if defined, otherwise earlier
  MergedSchema = case Schema2 of
    undefined -> Schema1;
    _ -> Schema2
  end,
  #resource{
    attributes = MergedAttrs,
    schema_url = MergedSchema
  }.

%% @doc Gets the attributes from a resource.
-spec get_attributes(#resource{}) -> map().
get_attributes(#resource{attributes = Attrs}) ->
  Attrs.

%% @doc Gets the schema URL from a resource.
-spec get_schema_url(#resource{}) -> binary() | undefined.
get_schema_url(#resource{schema_url = Schema}) ->
  Schema.

%% @doc Sets the global default resource.
-spec set_default(#resource{}) -> ok.
set_default(#resource{} = Resource) ->
  persistent_term:put(?DEFAULT_RESOURCE_KEY, Resource),
  ok.

%% @doc Gets the global default resource.
-spec get_default() -> #resource{}.
get_default() ->
  case persistent_term:get(?DEFAULT_RESOURCE_KEY, undefined) of
    undefined ->
      Resource = default(),
      set_default(Resource),
      Resource;
    Resource ->
      Resource
  end.
