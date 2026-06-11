%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc The series store: one family per logical metric name, one row per
%% live label set. Families and rows are claimed with ets:insert_new (the
%% arbiter row carries the payload) and published to persistent_term under
%% fresh keys only — no key is ever replaced on a designed path, so creation
%% never schedules a literal-GC sweep. Enumeration uses atomics-minted
%% sequence chains; see the design spec
%% docs/superpowers/specs/2026-06-11-p5-series-store-design.md.
-module(instrument_series).

-include("instrument.hrl").

-export([
  init/0,
  ensure_family/5,
  ensure_custom/2,
  family/1
]).

-define(TAB, instrument_series).

%% Called from instrument_registry:init/1 (the registry owns the tables).
init() ->
  _ = ets:new(?TAB, [set, public, named_table, {write_concurrency, auto}]),
  FamSeq = atomics:new(1, []),
  persistent_term:put(instrument_family_seq, FamSeq),
  ok.

%% Create-or-get a family. Duplicate create returns the existing meta without
%% a kind check (master parity).
-spec ensure_family(term(), atom(), binary(), [term()] | undefined,
                    [number()] | undefined) -> #family{}.
ensure_family(Name, Kind, Help, DeclaredLabels, Boundaries) ->
  FamSeq = persistent_term:get(instrument_family_seq),
  Meta = #family{
    kind = Kind,
    help = Help,
    declared_labels = DeclaredLabels,
    boundaries = Boundaries,
    start_time = erlang:system_time(nanosecond),
    idx = atomics:add_get(FamSeq, 1, 1),
    row_seq = atomics:new(1, [])
  },
  case ets:insert_new(?TAB, {{Name, family}, Meta}) of
    true ->
      publish_family(Name, Meta),
      Meta;
    false ->
      Existing = ets:lookup_element(?TAB, {Name, family}, 2),
      %% dead-creator repair: complete missing pt publications (two racing
      %% repairers can produce one redundant replacing put — recovery path
      %% only, vanishingly rare)
      case persistent_term:get({instrument_family, Name}, undefined) of
        undefined -> publish_family(Name, Existing);
        _ -> ok
      end,
      Existing
  end.

%% Custom-collector family (instrument_metric:register/1 compat).
-spec ensure_custom(term(), {module(), atom(), list()}) -> ok.
ensure_custom(Name, MFA) ->
  FamSeq = persistent_term:get(instrument_family_seq),
  Meta = {custom, MFA, atomics:add_get(FamSeq, 1, 1)},
  case ets:insert_new(?TAB, {{Name, family}, Meta}) of
    true ->
      publish_family(Name, Meta),
      ok;
    false ->
      %% no dead-creator repair: custom families are registered at startup by a single caller; first_write never reads them
      ok
  end.

publish_family(Name, #family{idx = Idx} = Meta) ->
  persistent_term:put({instrument_family_idx, Idx}, Name),
  persistent_term:put({instrument_family, Name}, Meta),
  ok;
publish_family(Name, {custom, _, Idx} = Meta) ->
  persistent_term:put({instrument_family_idx, Idx}, Name),
  persistent_term:put({instrument_family, Name}, Meta),
  ok.

%% Family lookup: pt fast path, arbiter-row fallback (degraded mode after a
%% creator died mid-publication).
-spec family(term()) -> #family{} | {custom, {module(), atom(), list()}, pos_integer()} | undefined.
family(Name) ->
  case persistent_term:get({instrument_family, Name}, undefined) of
    undefined ->
      try ets:lookup_element(?TAB, {Name, family}, 2)
      catch error:badarg -> undefined
      end;
    Meta ->
      Meta
  end.
