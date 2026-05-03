%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Retry helper for OTLP exporters.
%%
%% Classifies HTTP / network errors as `retryable' or `permanent' per the
%% OpenTelemetry specification and implements bounded exponential backoff
%% with optional `Retry-After' header support.
-module(instrument_otlp_retry).
-author("benoitc").

-export([
  classify_error/1,
  send_with_retry/5,
  send_with_retry/6
]).

-type http_result() :: ok | {error, retryable, term()} | {error, permanent, term()}.

-export_type([http_result/0]).

%% @doc Classifies an HTTP / hackney error as retryable or permanent.
%% Retryable: 408, 429, and 5xx except 501; transient transport failures
%% (timeout, closed, econnrefused, nxdomain, ehostunreach, enetunreach).
%% Everything else is permanent.
-spec classify_error(term()) -> retryable | permanent.
classify_error({http_error, Status, _}) when is_integer(Status) ->
  classify_status(Status);
classify_error({http_status, Status}) when is_integer(Status) ->
  classify_status(Status);
classify_error(timeout) -> retryable;
classify_error(closed) -> retryable;
classify_error(connect_timeout) -> retryable;
classify_error(checkout_timeout) -> retryable;
classify_error(econnrefused) -> retryable;
classify_error(econnreset) -> retryable;
classify_error(ehostunreach) -> retryable;
classify_error(enetunreach) -> retryable;
classify_error(nxdomain) -> retryable;
classify_error(_) -> permanent.

classify_status(408) -> retryable;
classify_status(429) -> retryable;
classify_status(502) -> retryable;
classify_status(503) -> retryable;
classify_status(504) -> retryable;
classify_status(_) -> permanent.

%% @equiv send_with_retry(Method, Url, Headers, Body, Options, #{})
-spec send_with_retry(
  atom(), binary(), list(), iodata(), list()
) -> http_result().
send_with_retry(Method, Url, Headers, Body, Options) ->
  send_with_retry(Method, Url, Headers, Body, Options, #{}).

%% @doc Sends an HTTP request with bounded exponential backoff.
%% On a retryable error, waits `min(InitialDelay * 2^Attempt, MaxDelay)' and
%% retries up to `MaxRetries' additional times (so `MaxRetries + 1' total
%% attempts). If the response carries a `Retry-After' header (seconds or
%% HTTP-date) the value is clamped to `[0, MaxDelay]' and used as the next
%% delay.
-spec send_with_retry(
  atom(), binary(), list(), iodata(), list(),
  #{max_retries => non_neg_integer(),
    initial_delay_ms => pos_integer(),
    max_delay_ms => pos_integer()}
) -> http_result().
send_with_retry(Method, Url, Headers, Body, Options, Opts) ->
  MaxRetries = maps:get(max_retries, Opts, instrument_config:get_otlp_max_retries()),
  InitialDelay = maps:get(initial_delay_ms, Opts, instrument_config:get_otlp_retry_initial_delay_ms()),
  MaxDelay = maps:get(max_delay_ms, Opts, instrument_config:get_otlp_retry_max_delay_ms()),
  do_send(Method, Url, Headers, Body, Options,
          0, MaxRetries, InitialDelay, MaxDelay).

do_send(Method, Url, Headers, Body, Options,
        Attempt, MaxRetries, InitialDelay, MaxDelay) ->
  case hackney:request(Method, Url, Headers, Body, Options) of
    {ok, Status, _RespHeaders, _RespBody} when Status >= 200, Status < 300 ->
      ok;
    {ok, Status, RespHeaders, RespBody} ->
      Error = {http_error, Status, RespBody},
      case classify_error(Error) of
        retryable when Attempt < MaxRetries ->
          Delay = retry_delay(RespHeaders, Attempt, InitialDelay, MaxDelay),
          timer:sleep(Delay),
          do_send(Method, Url, Headers, Body, Options,
                  Attempt + 1, MaxRetries, InitialDelay, MaxDelay);
        retryable ->
          {error, retryable, Error};
        permanent ->
          {error, permanent, Error}
      end;
    {error, Reason} ->
      case classify_error(Reason) of
        retryable when Attempt < MaxRetries ->
          Delay = backoff_delay(Attempt, InitialDelay, MaxDelay),
          timer:sleep(Delay),
          do_send(Method, Url, Headers, Body, Options,
                  Attempt + 1, MaxRetries, InitialDelay, MaxDelay);
        retryable ->
          {error, retryable, Reason};
        permanent ->
          {error, permanent, Reason}
      end
  end.

retry_delay(RespHeaders, Attempt, InitialDelay, MaxDelay) ->
  case retry_after_ms(RespHeaders) of
    undefined ->
      backoff_delay(Attempt, InitialDelay, MaxDelay);
    Ms ->
      max(0, min(Ms, MaxDelay))
  end.

backoff_delay(Attempt, InitialDelay, MaxDelay) ->
  min(InitialDelay * (1 bsl Attempt), MaxDelay).

%% Parse Retry-After header, which may be a delay in seconds or an HTTP-date.
%% Header lookup is case-insensitive.
retry_after_ms(Headers) ->
  case header_value(<<"retry-after">>, Headers) of
    undefined -> undefined;
    Value ->
      Trimmed = string:trim(to_binary(Value)),
      case catch binary_to_integer(Trimmed) of
        Sec when is_integer(Sec), Sec >= 0 -> Sec * 1000;
        _ -> undefined
      end
  end.

header_value(_Name, []) ->
  undefined;
header_value(Name, [{K, V} | Rest]) ->
  case string:equal(to_binary(K), Name, true) of
    true -> V;
    false -> header_value(Name, Rest)
  end.

to_binary(V) when is_binary(V) -> V;
to_binary(V) when is_list(V) -> list_to_binary(V);
to_binary(V) when is_atom(V) -> atom_to_binary(V, utf8).
