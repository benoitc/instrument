%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_registry_restart_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("instrument_otel.hrl").

-export([
  all/0,
  init_per_testcase/2,
  end_per_testcase/2
]).

-export([registry_restart_self_heals/1]).

all() -> [registry_restart_self_heals].

init_per_testcase(_, Config) ->
  _ = application:stop(instrument),
  {ok, _} = application:ensure_all_started(instrument),
  Config.

end_per_testcase(_, _Config) ->
  _ = application:stop(instrument),
  ok.

%% A registry restart (here, stop+start of the app so init/1 runs) used to leave
%% stale {otel_instrument, Name}/otel_instruments persistent_term entries behind.
%% get_instrument/1 then returned the stale record, create_* short-circuited
%% without re-registering, and the metric vanished from collect_all/format while
%% add kept "succeeding". The registry must now be a clean slate on restart.
registry_restart_self_heals(_Config) ->
  Name  = <<"restart_heal_counter">>,
  Meter = instrument_meter:get_meter(<<"restart_test">>),
  C1    = instrument_meter:create_up_down_counter(Meter, Name),
  ?assertMatch(#otel_instrument{name = Name}, C1),
  ok = instrument_meter:add(C1, 7),
  %% present before restart
  ?assertMatch(#otel_instrument{}, instrument_meter:get_instrument(Name)),
  true = name_in_collect_all(Name),
  ?assertNotEqual(nomatch, binary:match(instrument_prometheus:format(), Name)),

  %% restart the registry by stopping/starting the app so init/1 runs
  ok = application:stop(instrument),
  {ok, _} = application:ensure_all_started(instrument),

  %% clean slate: the stale instrument record must be gone
  ?assertEqual(undefined, instrument_meter:get_instrument(Name)),
  ?assertEqual(false, name_in_collect_all(Name)),

  %% recreating + recording self-heals the metric
  Meter2 = instrument_meter:get_meter(<<"restart_test">>),
  C2     = instrument_meter:create_up_down_counter(Meter2, Name),
  ok = instrument_meter:add(C2, 3),
  ?assertMatch(#otel_instrument{}, instrument_meter:get_instrument(Name)),
  true = name_in_collect_all(Name),
  ?assertNotEqual(nomatch, binary:match(instrument_prometheus:format(), Name)),
  ok.

%% collect_all/0 returns metric maps whose name is either the binary Name or a
%% tuple carrying it (e.g. {otel, Name}); match either shape.
name_in_collect_all(Name) ->
  lists:any(fun(#{name := N}) -> name_matches(N, Name);
               (_) -> false
            end, instrument_registry:collect_all()).

name_matches(Name, Name) -> true;
name_matches(N, Name) when is_tuple(N) ->
  lists:member(Name, tuple_to_list(N));
name_matches(_, _) -> false.
