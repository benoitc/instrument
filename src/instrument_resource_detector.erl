%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc OpenTelemetry Resource Detector behavior and built-in detectors.
%%
%% Resource detectors automatically discover attributes about the
%% environment where the application is running.
%%
%% == Built-in Detectors ==
%% - `env' - Reads OTEL_RESOURCE_ATTRIBUTES environment variable
%% - `process' - Detects process information (runtime, command, etc.)
%% - `host' - Detects host information (hostname, OS, arch)
%%
%% == Example Usage ==
%% ```
%% %% Register a custom detector
%% instrument_resource_detector:register(my_detector, fun() ->
%%   instrument_resource:create(#{<<"custom.attr">> => <<"value">>})
%% end).
%%
%% %% Detect all resources
%% Resource = instrument_resource_detector:detect_all().
%% '''
-module(instrument_resource_detector).
-author("benoitc").

-include("instrument_otel.hrl").

%% API
-export([
  register/2,
  unregister/1,
  list/0,
  detect_all/0,
  detect/1
]).

%% Built-in detectors
-export([
  detect_env/0,
  detect_process/0,
  detect_host/0,
  detect_service/0
]).

-define(DETECTORS_KEY, '$instrument_resource_detectors').

%% ============================================================================
%% API
%% ============================================================================

%% @doc Registers a resource detector.
%% The detector is a function that returns a #resource{}.
-spec register(atom(), fun(() -> #resource{})) -> ok.
register(Name, DetectorFun) when is_atom(Name), is_function(DetectorFun, 0) ->
  Detectors = persistent_term:get(?DETECTORS_KEY, default_detectors()),
  NewDetectors = [{Name, DetectorFun} | lists:keydelete(Name, 1, Detectors)],
  persistent_term:put(?DETECTORS_KEY, NewDetectors),
  ok.

%% @doc Unregisters a resource detector.
-spec unregister(atom()) -> ok.
unregister(Name) when is_atom(Name) ->
  Detectors = persistent_term:get(?DETECTORS_KEY, default_detectors()),
  NewDetectors = lists:keydelete(Name, 1, Detectors),
  persistent_term:put(?DETECTORS_KEY, NewDetectors),
  ok.

%% @doc Lists all registered detectors.
-spec list() -> [atom()].
list() ->
  Detectors = persistent_term:get(?DETECTORS_KEY, default_detectors()),
  [Name || {Name, _} <- Detectors].

%% @doc Runs all registered detectors and merges results.
-spec detect_all() -> #resource{}.
detect_all() ->
  Detectors = persistent_term:get(?DETECTORS_KEY, default_detectors()),
  lists:foldl(fun({_Name, DetectorFun}, AccResource) ->
    try
      DetectedResource = DetectorFun(),
      instrument_resource:merge(AccResource, DetectedResource)
    catch
      _:_ -> AccResource
    end
  end, instrument_resource:empty(), Detectors).

%% @doc Runs a specific detector by name.
-spec detect(atom()) -> #resource{} | {error, not_found}.
detect(Name) when is_atom(Name) ->
  Detectors = persistent_term:get(?DETECTORS_KEY, default_detectors()),
  case lists:keyfind(Name, 1, Detectors) of
    {Name, DetectorFun} ->
      try
        DetectorFun()
      catch
        _:_ -> instrument_resource:empty()
      end;
    false ->
      {error, not_found}
  end.

%% ============================================================================
%% Built-in Detectors
%% ============================================================================

%% @doc Detects resource attributes from OTEL_RESOURCE_ATTRIBUTES env var.
%% Format: key1=value1,key2=value2
-spec detect_env() -> #resource{}.
detect_env() ->
  case os:getenv("OTEL_RESOURCE_ATTRIBUTES") of
    false ->
      instrument_resource:empty();
    Value ->
      Attrs = parse_env_attributes(Value),
      instrument_resource:create(Attrs)
  end.

%% @doc Detects process-related attributes.
-spec detect_process() -> #resource{}.
detect_process() ->
  Attrs = #{
    <<"process.runtime.name">> => <<"BEAM">>,
    <<"process.runtime.version">> => list_to_binary(erlang:system_info(otp_release)),
    <<"process.runtime.description">> => list_to_binary(
      erlang:system_info(system_version) -- "\n"
    ),
    <<"process.pid">> => list_to_binary(os:getpid())
  },
  %% Add command if available
  Attrs2 = case init:get_argument(progname) of
    {ok, [[ProgName | _] | _]} ->
      Attrs#{<<"process.executable.name">> => list_to_binary(ProgName)};
    _ ->
      Attrs
  end,
  instrument_resource:create(Attrs2).

%% @doc Detects host-related attributes.
-spec detect_host() -> #resource{}.
detect_host() ->
  {ok, Hostname} = inet:gethostname(),
  Attrs = #{
    <<"host.name">> => list_to_binary(Hostname),
    <<"host.arch">> => list_to_binary(erlang:system_info(system_architecture))
  },
  %% Add OS info
  {OsFamily, OsName} = os:type(),
  Attrs2 = Attrs#{
    <<"os.type">> => atom_to_binary(OsFamily, utf8),
    <<"os.description">> => atom_to_binary(OsName, utf8)
  },
  instrument_resource:create(Attrs2).

%% @doc Detects service identity from config and environment.
%% Reads service.name from OTEL_SERVICE_NAME, service.version from
%% OTEL_SERVICE_VERSION, and custom attributes from application config.
-spec detect_service() -> #resource{}.
detect_service() ->
  %% Start with resource attributes from application config
  ConfigAttrs = instrument_config:get_resource_config(),
  ServiceName = instrument_config:get_service_name(),
  ServiceVersion = instrument_config:get_service_version(),

  Attrs0 = maps:merge(#{}, ConfigAttrs),
  Attrs1 = case ServiceName of
    undefined -> Attrs0;
    Name -> Attrs0#{<<"service.name">> => Name}
  end,
  Attrs2 = case ServiceVersion of
    undefined -> Attrs1;
    Version -> Attrs1#{<<"service.version">> => Version}
  end,
  instrument_resource:create(Attrs2).

%% ============================================================================
%% Internal Functions
%% ============================================================================

default_detectors() ->
  [
    {service, fun detect_service/0},
    {env, fun detect_env/0},
    {process, fun detect_process/0},
    {host, fun detect_host/0}
  ].

parse_env_attributes(Value) ->
  Pairs = string:split(Value, ",", all),
  lists:foldl(fun(Pair, Acc) ->
    case string:split(Pair, "=", leading) of
      [Key, Val] ->
        K = string:trim(Key),
        V = string:trim(Val),
        Acc#{list_to_binary(K) => list_to_binary(V)};
      _ ->
        Acc
    end
  end, #{}, Pairs).
