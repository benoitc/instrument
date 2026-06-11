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
  family/1,
  write/4
]).

-define(TAB, instrument_series).
-define(COUNTS, instrument_label_counts).
-define(OVERFLOW_VALUE, <<"otel.metric.overflow">>).

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
      case ets:lookup_element(?TAB, {Name, family}, 2, undefined) of
        undefined ->
          %% concurrent teardown deleted the arbiter row; the claim is free again
          ensure_family(Name, Kind, Help, DeclaredLabels, Boundaries);
        Existing ->
          %% dead-creator repair: complete missing pt publications (two racing
          %% repairers can produce one redundant replacing put — recovery path
          %% only, vanishingly rare)
          case persistent_term:get({instrument_family, Name}, undefined) of
            undefined -> publish_family(Name, Existing);
            _ -> ok
          end,
          Existing
      end
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

%% The unified write path. CacheKey is the API's natural input shape (meter:
%% Canon; vec API: raw values list). CanonFun computes the canonical
%% {SortedNames, Values} only on first touch.
-spec write(term(), term(), fun(() -> {list(), list()}),
            fun((#metric{}) -> any())) -> any().
write(Name, CacheKey, CanonFun, WriteFun) ->
  case persistent_term:get({instrument_label, Name, CacheKey}, undefined) of
    #metric{} = Row -> WriteFun(Row);
    undefined -> first_write(Name, CacheKey, CanonFun, WriteFun)
  end.

first_write(Name, CacheKey, CanonFun, WriteFun) ->
  case family(Name) of
    undefined -> {error, not_found};
    {custom, _, _} -> {error, not_found};
    #family{} = Fam ->
      Canon = CanonFun(),
      case valid_arity(Fam, Canon) of
        false -> {error, invalid_labels};
        true ->
          case over_limit(Name, Canon) of
            true -> overflow_write(Name, Fam, WriteFun);
            false -> claim_row(Name, Fam, Canon, CacheKey, WriteFun)
          end
      end
  end.

valid_arity(#family{declared_labels = undefined}, _Canon) -> true;
valid_arity(#family{declared_labels = Declared}, {Names, _Values}) ->
  length(Names) =:= length(Declared).

over_limit(Name, Canon) ->
  overflow_canon_marker(Canon) =:= not_overflow andalso
    instrument_registry:label_count(Name) >=
      instrument_config:get_metric_cardinality_limit().

%% An overflow canon is exempt from the cap check (it must be creatable AT the
%% cap). Both per-API shapes carry only ?OVERFLOW_VALUE / <<"true">> values.
overflow_canon_marker({[?OVERFLOW_VALUE], [<<"true">>]}) ->
  overflow;
overflow_canon_marker({_Names, Values} = Canon) ->
  case Values =/= [] andalso lists:all(fun(V) -> V =:= ?OVERFLOW_VALUE end, Values) of
    true -> Canon;
    false -> not_overflow
  end;
overflow_canon_marker(_) ->
  not_overflow.

overflow_write(Name, #family{declared_labels = Declared}, WriteFun) ->
  _ = ets:update_counter(?COUNTS, {dropped, Name}, {2, 1}, {{dropped, Name}, 0}),
  Canon = overflow_canon(Declared),
  %% overflow rows resolve through the ordinary path (cache hit when hot)
  write(Name, Canon, fun() -> Canon end, WriteFun).

overflow_canon(undefined) ->
  {[?OVERFLOW_VALUE], [<<"true">>]};
overflow_canon(Declared) ->
  Sorted = lists:sort(Declared),
  {Sorted, [?OVERFLOW_VALUE || _ <- Sorted]}.

claim_row(Name, #family{} = Fam, Canon, CacheKey, WriteFun) ->
  Row = mint_row(Name, Fam, Canon),
  case ets:insert_new(?TAB, {{Name, Canon}, Row}) of
    true ->
      %% post-claim family re-check (narrows the unregister race): teardown
      %% deletes the family arbiter row first
      case ets:member(?TAB, {Name, family}) of
        false ->
          ets:delete(?TAB, {Name, Canon}),
          discard_row(Row),
          {error, not_found};
        true ->
          S = atomics:add_get(Fam#family.row_seq, 1, 1),
          persistent_term:put({instrument_row, Name, S}, {Canon, CacheKey, Row}),
          persistent_term:put({instrument_label, Name, CacheKey}, Row),
          _ = ets:update_counter(?COUNTS, {count, Name}, {2, 1}, {{count, Name}, 0}),
          WriteFun(Row)
      end;
    false ->
      discard_row(Row),
      case ets:lookup_element(?TAB, {Name, Canon}, 2, undefined) of
        undefined -> {error, not_found};   %% winner undid its claim (family torn down)
        #metric{} = Existing -> WriteFun(Existing)
      end
  end.

%% Cells are master's exact storage shapes; rows are the same unregistered
%% #metric{} wrappers so per-kind ops work unmodified.
mint_row(Name, #family{kind = Kind, boundaries = Bounds}, Canon) ->
  RowName = {row, Name, Canon},
  Handle = mint_handle(Kind, Bounds, RowName),
  #metric{name = RowName, handle = Handle}.

mint_handle(counter, _Bounds, _RowName) ->
  {ok, Ref} = instrument_nif:new_gauge(),
  {Ref, erlang:system_time(nanosecond)};
mint_handle(Kind, _Bounds, _RowName)
    when Kind =:= up_down_counter; Kind =:= gauge;
         Kind =:= observable_counter; Kind =:= observable_gauge;
         Kind =:= observable_up_down_counter ->
  {ok, Ref} = instrument_nif:new_gauge(),
  Ref;
mint_handle(histogram, Bounds0, RowName) ->
  Bounds = case Bounds0 of
    undefined -> instrument_histogram:default_buckets();
    _ -> Bounds0
  end,
  (instrument_histogram:new_histogram(RowName, <<>>, Bounds))#metric.handle.

%% A loser's freshly minted cell: NIF/atomics memory is reclaimed by refcount;
%% a histogram's exemplar reservoir lives in ETS and must be released.
discard_row(#metric{} = Row) ->
  instrument_histogram:cleanup(Row).
