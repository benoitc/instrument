%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

-module(instrument_lib).
-author("benoitc").

%% API
-export([
  mk_info/2,
  safe_call/1,
  safe_call/2,
  safe_apply/4,
  bounded_env/4,
  json_encode/1,
  chars_to_binary/1,
  redact_status/1,
  redact_message/1,
  take_members/4,
  escape_control/1
]).

-include("instrument.hrl").

mk_info(Name, Help) ->
  #metric_info{name=Name, help=Help}.


%% @doc Run a 0-arity fun, ignoring any exception. Returns `ok' on failure.
-spec safe_call(fun(() -> term())) -> term().
safe_call(Fun) ->
  safe_call(Fun, ok).

%% @doc Run a 0-arity fun, returning `Default' on any exception.
-spec safe_call(fun(() -> term()), term()) -> term().
safe_call(Fun, Default) when is_function(Fun, 0) ->
  try Fun() catch _:_ -> Default end.

%% @doc Best-effort apply/3, returning `Default' on any exception.
-spec safe_apply(module(), atom(), [term()], term()) -> term().
safe_apply(M, F, A, Default) ->
  try apply(M, F, A) catch _:_ -> Default end.


%% @doc Reads an integer from the `instrument' application env, accepting
%% values in `[Min, Max]'. Returns `Default' when the key is unset; logs a
%% warning and returns `Default' when the value is out of range or not an
%% integer.
-spec bounded_env(atom(), integer(), integer(), integer()) -> integer().
bounded_env(Key, Default, Min, Max) ->
  case application:get_env(instrument, Key) of
    undefined -> Default;
    {ok, V} when is_integer(V), V >= Min, V =< Max -> V;
    {ok, Bad} ->
      logger:warning("instrument: ignoring invalid ~p value ~p, using ~p",
                     [Key, Bad, Default]),
      Default
  end.

%% @doc json:encode/1 for telemetry payloads. Strings come from spans, logs
%% and metrics, often from the network; one invalid UTF-8 binary made
%% json:encode/1 raise and the whole export batch was dropped. Invalid bytes
%% are replaced by U+FFFD before encoding.
-spec json_encode(term()) -> iodata().
json_encode(Term) ->
  json:encode(utf8_safe(Term)).

utf8_safe(B) when is_binary(B) ->
  case unicode:characters_to_binary(B) of
    B -> B;
    _ -> fix_utf8(B, <<>>)
  end;
utf8_safe(M) when is_map(M) ->
  maps:fold(fun(K, V, Acc) -> Acc#{utf8_safe(K) => utf8_safe(V)} end, #{}, M);
utf8_safe(L) when is_list(L) ->
  [utf8_safe(E) || E <- L];
utf8_safe(Other) ->
  Other.

fix_utf8(<<>>, Acc) ->
  Acc;
fix_utf8(Bin, Acc) ->
  case unicode:characters_to_binary(Bin) of
    Good when is_binary(Good) ->
      <<Acc/binary, Good/binary>>;
    {error, Good, <<_Bad, Rest/binary>>} ->
      fix_utf8(Rest, <<Acc/binary, Good/binary, 16#EF, 16#BF, 16#BD>>);
    {incomplete, Good, _Rest} ->
      <<Acc/binary, Good/binary, 16#EF, 16#BF, 16#BD>>
  end.

%% @doc Text to a UTF-8 binary. Accepts binaries, byte lists and Unicode
%% chardata (environment variables under +fnu, `~ts' output); anything that
%% is not text is printed. Unlike list_to_binary/1 it does not raise on code
%% points above 255.
-spec chars_to_binary(term()) -> binary().
chars_to_binary(B) when is_binary(B) ->
  B;
chars_to_binary(L) when is_list(L) ->
  try unicode:characters_to_binary(L) of
    B when is_binary(B) -> B;
    _ -> printed(L)
  catch _:_ -> printed(L)
  end;
chars_to_binary(A) when is_atom(A) ->
  atom_to_binary(A, utf8);
chars_to_binary(Other) ->
  printed(Other).

printed(Term) ->
  unicode:characters_to_binary(io_lib:format("~0tp", [Term])).

%% @doc format_status/1 helper for processes holding exporter configuration:
%% drops the state (it carries authorization headers) and the configuration
%% in a pending register call from crash reports and sys:get_status/1.
-spec redact_status(map()) -> map().
redact_status(Status) ->
  maps:map(fun(state, _) -> redacted;
              (message, Msg) -> redact_message(Msg);
              (_, V) -> V
           end, Status).

-spec redact_message(term()) -> term().
redact_message({register, Module, _Config}) -> {register, Module, redacted};
redact_message(Msg) -> Msg.

%% @doc The first members of a separated header value, at most `MaxCount'
%% members and `MaxBytes' bytes of them. Splits one member at a time, so the
%% rest of an oversized header is never scanned or copied. Empty members are
%% skipped.
-spec take_members(binary(), binary(), non_neg_integer(), non_neg_integer()) -> [binary()].
take_members(Bin, Sep, MaxCount, MaxBytes) ->
  take_members(Bin, Sep, MaxCount, MaxBytes, []).

take_members(<<>>, _Sep, _Count, _Bytes, Acc) ->
  lists:reverse(Acc);
take_members(_Bin, _Sep, 0, _Bytes, Acc) ->
  lists:reverse(Acc);
take_members(Bin, Sep, Count, Bytes, Acc) ->
  {Member, Rest} = case binary:split(Bin, Sep) of
                     [M, R] -> {M, R};
                     [M] -> {M, <<>>}
                   end,
  case byte_size(Member) of
    0 -> take_members(Rest, Sep, Count, Bytes, Acc);
    Size when Size > Bytes -> lists:reverse(Acc);
    Size -> take_members(Rest, Sep, Count - 1, Bytes - Size - 1, [Member | Acc])
  end.

%% @doc Escapes control characters so a text value stays on one line: `\n',
%% `\r' and `\t' become two-character escapes, other control bytes and DEL
%% become `\xHH'. Other bytes, including UTF-8, are unchanged.
-spec escape_control(binary()) -> binary().
escape_control(Bin) when is_binary(Bin) ->
  case has_control(Bin) of
    false -> Bin;
    true -> << <<(escape_byte(C))/binary>> || <<C>> <= Bin >>
  end.

has_control(<<>>) -> false;
has_control(<<C, _/binary>>) when C < 32; C =:= 127 -> true;
has_control(<<_, Rest/binary>>) -> has_control(Rest).

escape_byte($\n) -> <<"\\n">>;
escape_byte($\r) -> <<"\\r">>;
escape_byte($\t) -> <<"\\t">>;
escape_byte(C) when C < 32; C =:= 127 ->
  Hex = string:lowercase(integer_to_binary(C, 16)),
  Pad = case byte_size(Hex) of 1 -> <<"0">>; _ -> <<>> end,
  <<"\\x", Pad/binary, Hex/binary>>;
escape_byte(C) -> <<C>>.
