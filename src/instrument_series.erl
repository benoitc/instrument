%% Copyright (c) 2026, Grigory Starinkin <starinkin@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc The series store: one family per logical metric name, one row per
%% live label set. Families and rows are claimed with ets:insert_new (the
%% arbiter row carries the payload) and published to persistent_term under
%% fresh keys only — no key is ever replaced on a designed path, so creation
%% never schedules a literal-GC sweep. Enumeration uses atomics-minted
%% sequence chains.
-module(instrument_series).

-include("instrument.hrl").

-export([
  init/0,
  reset/0,
  ensure_family/5,
  ensure_custom/2,
  family/1,
  write/4,
  collect_all/0,
  remove_row/2,
  clear_family_rows/1,
  teardown_family/1,
  to_label_value/1,
  vec_canon/2,
  %% exported for the registry's overflow_sentinel resolution
  overflow_canon/1
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

%% Reset the series store to a clean-but-initialized state. Called from the
%% registry's full-reset path (unregister_all / do_delete_all), which sweeps
%% every instrument-owned persistent_term key — including instrument_family_seq
%% — so the seq counter must be re-minted here or the next ensure_family/write
%% would fail on the missing ref. Clears the arbiter rows too so a re-created
%% same-named family wins its insert_new claim cleanly. The per-family chain pt
%% keys (instrument_row/instrument_label/instrument_family*) are erased by the
%% registry's own sweep; this only owns the ETS state and the seq ref.
-spec reset() -> ok.
reset() ->
  case ets:info(?TAB, name) of
    undefined -> ok;
    _ -> ets:delete_all_objects(?TAB)
  end,
  persistent_term:put(instrument_family_seq, atomics:new(1, [])),
  ok.

%% Read the live family-sequence atomics ref. During unregister_all the registry
%% sweeps instrument_family_seq out of persistent_term and reset/0 re-mints a
%% fresh ref — there is a brief window where the key is absent. Rather than
%% crashing with badarg, spin with erlang:yield() up to 50 times waiting for
%% reset/0 to complete, then raise a clear error if it never arrives.
family_seq() ->
  family_seq(50).

family_seq(0) ->
  error(instrument_series_not_initialized);
family_seq(N) ->
  case persistent_term:get(instrument_family_seq, undefined) of
    undefined ->
      erlang:yield(),
      family_seq(N - 1);
    Ref ->
      Ref
  end.

%% Create-or-get a family. Duplicate create returns the existing meta without
%% a kind check (master parity).
-spec ensure_family(term(), atom(), binary(), [term()] | undefined,
                    [number()] | undefined) -> #family{}.
ensure_family(Name, Kind, Help, DeclaredLabels, Boundaries) ->
  FamSeq = family_seq(),
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

%% Custom family (instrument_metric:register/1 compat). The payload is either a
%% collect MFA {M,F,A} (scraped by collect_all) or {raw, #metric{}} — a record
%% registered with no collector, stored verbatim so lookup/1 round-trips it and
%% collect_all skips it (master case_clause-crashed on collectorless records; a
%% silent skip is strictly better). Returns {error, already_exists} when the
%% name is taken, so register/1 reports duplicate registrations.
-spec ensure_custom(term(), {module(), atom(), list()} | {raw, #metric{}}) ->
        ok | {error, already_exists}.
ensure_custom(Name, Payload) ->
  FamSeq = family_seq(),
  Meta = {custom, Payload, atomics:add_get(FamSeq, 1, 1)},
  case ets:insert_new(?TAB, {{Name, family}, Meta}) of
    true ->
      publish_family(Name, Meta),
      ok;
    false ->
      %% no dead-creator repair: custom families are registered at startup by a single caller; first_write never reads them
      {error, already_exists}
  end.

publish_family(Name, #family{idx = Idx} = Meta) ->
  persistent_term:put({instrument_family_idx, Idx}, Name),
  persistent_term:put({instrument_family, Name}, Meta),
  ok;
publish_family(Name, {custom, _, Idx} = Meta) ->
  persistent_term:put({instrument_family_idx, Idx}, Name),
  persistent_term:put({instrument_family, Name}, Meta),
  ok.

-type custom_payload() :: {module(), atom(), list()} | {raw, #metric{}}.

%% Family lookup: pt fast path, arbiter-row fallback (degraded mode after a
%% creator died mid-publication).
-spec family(term()) -> #family{} | {custom, custom_payload(), pos_integer()} | undefined.
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
  %% A degenerate sentinel {[], [_|_]} can only arise from a vec-style
  %% arity-mismatch reaching a schema-free or []-declared family; reject it
  %% here so it never mints a cell or occupies a chain slot.
  case Canon of
    {[], [_|_]} ->
      {error, invalid_labels};
    _ ->
      {Names, _Values} = Canon,
      %% canonical names must arrive sorted: the scrape-time union umerge and the
      %% ordered chain rendering both depend on it; cheap to assert once per series
      true = (Names =:= lists:sort(Names)),
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
              %% The overflow row is a real chain slot but is NOT a live label set:
              %% it is cap-exempt and tracked by {dropped, Name}, so it must not
              %% bump the live-series count (which feeds label_count/1 and the cap).
              case overflow_canon_marker(Canon) of
                not_overflow ->
                  _ = ets:update_counter(?COUNTS, {count, Name}, {2, 1}, {{count, Name}, 0});
                _ ->
                  ok
              end,
              WriteFun(Row)
          end;
        false ->
          discard_row(Row),
          case ets:lookup_element(?TAB, {Name, Canon}, 2, undefined) of
            undefined -> {error, not_found};   %% winner undid its claim (family torn down)
            #metric{} = Existing -> WriteFun(Existing)
          end
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

%% Pure literal-area reads: regenerate the key space from the counters, get
%% each slot from pt. No ETS on this path. Holes (unregistered families,
%% removed labels, in-flight publications) are skipped.
%% {custom, MFA} collectors must return formatter-compatible maps by convention.
-spec collect_all() -> [map()].
collect_all() ->
  %% defensive: callers can reach collect before the registry supervisor finishes init (early scrape); a missing seq ref means no families exist yet
  case persistent_term:get(instrument_family_seq, undefined) of
    undefined -> [];
    FamSeq -> collect_all(FamSeq)
  end.

collect_all(FamSeq) ->
  N = atomics:get(FamSeq, 1),
  lists:reverse(lists:foldl(fun(K, Acc) ->
    case persistent_term:get({instrument_family_idx, K}, undefined) of
      undefined -> Acc;
      Name ->
        case persistent_term:get({instrument_family, Name}, undefined) of
          undefined -> Acc;
          {custom, {raw, _Metric}, _Idx} ->
            %% a raw record carries no collector — nothing to emit
            Acc;
          {custom, {M, F, A}, _Idx} ->
            try [erlang:apply(M, F, A) | Acc]
            catch Class:Reason:Stacktrace ->
              logger:warning("Metric collector ~p:~p failed: ~p:~p",
                             [M, F, Class, Reason],
                             #{mfa => {M, F, length(A)}, stacktrace => Stacktrace}),
              Acc
            end;
          #family{} = Fam ->
            case collect_family(Name, Fam) of
              empty -> Acc;
              Entry -> [Entry | Acc]
            end
        end
    end
  end, [], lists:seq(1, N))).

collect_family(Name, #family{kind = Kind, help = Help, start_time = T0,
                             declared_labels = Declared, row_seq = Seq}) ->
  RowN = atomics:get(Seq, 1),
  {Data, Union0} = lists:foldl(fun(S, {DataAcc, UnionAcc}) ->
    case persistent_term:get({instrument_row, Name, S}, undefined) of
      undefined -> {DataAcc, UnionAcc};
      {{Names, Values}, _CacheKey, Row} ->
        Val = read_row(Kind, Row),
        %% Names is sorted by construction (canonical form); UnionAcc stays
        %% sorted as the umerge accumulator — umerge/2 requires both sorted.
        {[{Names, Values, Val} | DataAcc], lists:umerge(UnionAcc, Names)}
    end
  end, {[], []}, lists:seq(1, RowN)),
  case Data of
    [] -> empty;
    _ ->
      Union = case Declared of
        undefined -> Union0;
        _ -> lists:sort(Declared)
      end,
      #{name => Name, help => Help, type => wire_type(Kind),
        start_time => T0, labels => Union, data => lists:reverse(Data)}
  end.

read_row(counter, Row) -> instrument_counter:get_counter(Row);
read_row(histogram, Row) -> instrument_histogram:get_histogram(Row);
read_row(_GaugeLike, Row) -> instrument_gauge:get_gauge(Row).

wire_type(observable_counter) -> counter;
wire_type(up_down_counter) -> gauge;
wire_type(observable_gauge) -> gauge;
wire_type(observable_up_down_counter) -> gauge;
wire_type(K) -> K.

%% ============================================================================
%% Teardown helpers (admin-time, serialized by the registry gen_server).
%% Task 8 reuses these for full instrument teardown.
%% ============================================================================

%% Remove a single label set's row by its values-list cache key: erase the
%% cache key and the matching chain slot, drop the arbiter row, release the
%% row's exemplar reservoir, and decrement the live-series count. The chain
%% slot becomes a hole (scrapes skip it). Returns ok regardless of whether the
%% row existed.
-spec remove_row(term(), list()) -> ok.
remove_row(Name, CacheKey) ->
  case family(Name) of
    #family{row_seq = Seq} ->
      case persistent_term:get({instrument_label, Name, CacheKey}, undefined) of
        undefined ->
          ok;
        Row ->
          persistent_term:erase({instrument_label, Name, CacheKey}),
          %% the chain slot carries the Canon, so erasing it also drops the
          %% matching arbiter row (keyed by Canon)
          erase_matching_slot(Name, Seq, CacheKey),
          instrument_histogram:cleanup(Row),
          _ = ets:update_counter(?COUNTS, {count, Name}, {2, -1, 0, 0}, {{count, Name}, 0}),
          ok
      end;
    _ ->
      ok
  end.

%% Walk the chain to find the slot whose CacheKey matches; erase the chain slot
%% and delete the arbiter row keyed by that slot's Canon.
erase_matching_slot(Name, Seq, CacheKey) ->
  N = atomics:get(Seq, 1),
  lists:foreach(fun(S) ->
    case persistent_term:get({instrument_row, Name, S}, undefined) of
      {Canon, CK, _Row} when CK =:= CacheKey ->
        persistent_term:erase({instrument_row, Name, S}),
        ets:delete(?TAB, {Name, Canon});
      _ ->
        ok
    end
  end, lists:seq(1, N)).

%% Clear every live label set of a family: erase all cache keys and chain
%% slots, drop arbiter rows, release exemplar reservoirs, and delete the
%% {count, Name} accounting row. The family meta and its row_seq are
%% intentionally left untouched — re-minting row_seq would allow an in-flight
%% first-touch writer (which read the old meta before clear) to publish a slot
%% S on the shared {instrument_row, Name, S} keyspace that the new chain later
%% also mints, producing a replacing persistent_term:put on a creation path.
%% The single-writer-per-slot-key invariant must hold unconditionally; compaction
%% would require generation-keyed chains — rejected as overengineering for an
%% admin-time operation. New rows continue numbering from the existing high-water
%% mark; holes in the chain are the documented, accepted churn bound (§10).
-spec clear_family_rows(term()) -> ok.
clear_family_rows(Name) ->
  case persistent_term:get({instrument_family, Name}, undefined) of
    #family{row_seq = Seq} ->
      N = atomics:get(Seq, 1),
      lists:foreach(fun(S) ->
        case persistent_term:get({instrument_row, Name, S}, undefined) of
          {Canon, CacheKey, Row} ->
            persistent_term:erase({instrument_label, Name, CacheKey}),
            persistent_term:erase({instrument_row, Name, S}),
            ets:delete(?TAB, {Name, Canon}),
            instrument_histogram:cleanup(Row);
          undefined ->
            ok
        end
      end, lists:seq(1, N)),
      ets:delete(?COUNTS, {count, Name}),
      ok;
    _ ->
      ok
  end.

%% Full family teardown (§9 unregister ordering): delete the family arbiter row
%% and erase {instrument_family, Name} first (in-flight first-touches now fail
%% not_found, and winners' post-claim re-check catches most), then walk the
%% chain releasing each row, erase the family-idx hole, and delete the
%% count/dropped accounting. All erases; placement is admin-time.
-spec teardown_family(term()) -> ok.
teardown_family(Name) ->
  case family(Name) of
    #family{idx = Idx, row_seq = Seq} ->
      ets:delete(?TAB, {Name, family}),
      persistent_term:erase({instrument_family, Name}),
      N = atomics:get(Seq, 1),
      lists:foreach(fun(S) ->
        case persistent_term:get({instrument_row, Name, S}, undefined) of
          {Canon, CacheKey, Row} ->
            persistent_term:erase({instrument_label, Name, CacheKey}),
            persistent_term:erase({instrument_row, Name, S}),
            ets:delete(?TAB, {Name, Canon}),
            instrument_histogram:cleanup(Row);
          undefined ->
            ok
        end
      end, lists:seq(1, N)),
      persistent_term:erase({instrument_family_idx, Idx}),
      ets:delete(?COUNTS, {count, Name}),
      ets:delete(?COUNTS, {dropped, Name}),
      ok;
    {custom, _, Idx} ->
      ets:delete(?TAB, {Name, family}),
      persistent_term:erase({instrument_family, Name}),
      persistent_term:erase({instrument_family_idx, Idx}),
      ok;
    undefined ->
      ok
  end.

%% ============================================================================
%% Label canonicalization (shared by the meter, simple-metric, and vec APIs).
%% ============================================================================

%% Stringify a label value for the wire. One definition for all three APIs.
-spec to_label_value(term()) -> binary().
to_label_value(V) when is_binary(V)  -> V;
to_label_value(V) when is_list(V)    -> list_to_binary(V);
to_label_value(V) when is_atom(V)    -> atom_to_binary(V, utf8);
to_label_value(V) when is_integer(V) -> integer_to_binary(V);
to_label_value(V) when is_float(V)   -> float_to_binary(V, [{decimals, 6}, compact]).

%% Canonicalize a positional vec values list against the family's declared
%% names: sort by name, reorder values to match, stringify. On an arity
%% mismatch (or undefined declared labels) return the sentinel canon
%% {[], Values}; its empty names length cannot equal a non-empty declared list,
%% so valid_arity/2 rejects it as {error, invalid_labels} without a crash
%% (first_write/4 calls the CanonFun before its own arity check). A wrong-arity
%% values-list cache key never pre-exists, so this only runs on first touch.
-spec vec_canon([term()] | undefined, list()) -> {list(), list()}.
vec_canon(Declared, LabelValues)
    when is_list(Declared), length(Declared) =:= length(LabelValues) ->
  Pairs = lists:zip(Declared, LabelValues),
  Sorted = lists:keysort(1, Pairs),
  {[K || {K, _} <- Sorted], [to_label_value(V) || {_, V} <- Sorted]};
vec_canon(_Declared, LabelValues) ->
  {[], LabelValues}.
