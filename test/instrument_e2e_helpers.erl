%% Copyright (c) 2017-2026, Benoit Chesneau <bchesneau@gmail.com>.
%%
%% This file is part of instrument released under the MIT license.
%% See the NOTICE for more information.

%% @doc Helper functions for E2E tests with Docker containers.
-module(instrument_e2e_helpers).
-author("benoitc").

-include_lib("common_test/include/ct.hrl").

-export([
  docker_available/0,
  start_prometheus/2,
  start_jaeger/1,
  stop_container/1,
  wait_for_http/2,
  wait_for_prometheus_target/2,
  query_prometheus/2,
  query_jaeger_traces/2,
  start_metrics_server/1,
  stop_metrics_server/1
]).

%% @doc Checks if Docker is available on the system.
-spec docker_available() -> boolean().
docker_available() ->
  case os:cmd("docker --version 2>&1") of
    "Docker version" ++ _ -> true;
    _ -> false
  end.

%% @doc Starts a Prometheus container with a scrape config for the given port.
-spec start_prometheus(string(), pos_integer()) -> {ok, string()} | {error, term()}.
start_prometheus(Name, ScrapePort) ->
  TmpDir = "/tmp/prom_" ++ Name,
  %% On macOS, host.docker.internal works by default
  %% On Linux, we need --add-host flag (but it also supports host.docker.internal with that flag)
  ConfigContent = io_lib:format(
    "global:\n"
    "  scrape_interval: 1s\n"
    "  evaluation_interval: 1s\n"
    "scrape_configs:\n"
    "  - job_name: 'test'\n"
    "    static_configs:\n"
    "      - targets: ['host.docker.internal:~B']\n", [ScrapePort]),

  %% Create config directory
  _ = os:cmd("mkdir -p " ++ TmpDir),

  %% Write config file
  ConfigPath = TmpDir ++ "/prometheus.yml",
  case file:write_file(ConfigPath, ConfigContent) of
    ok ->
      %% Start container - use --add-host on Linux, not needed on macOS
      HostFlag = case os:type() of
        {unix, darwin} -> "";
        _ -> "--add-host=host.docker.internal:host-gateway "
      end,
      Cmd = io_lib:format(
        "docker run -d --name ~s -p 9090:9090 "
        "-v ~s:/etc/prometheus "
        "~s"
        "prom/prometheus:latest "
        "--config.file=/etc/prometheus/prometheus.yml "
        "--web.listen-address=0.0.0.0:9090 2>&1", [Name, TmpDir, HostFlag]),
      Result = os:cmd(lists:flatten(Cmd)),
      case string:find(Result, "Error") of
        nomatch -> {ok, Name};
        _ -> {error, Result}
      end;
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Starts a Jaeger all-in-one container.
-spec start_jaeger(string()) -> {ok, string()} | {error, term()}.
start_jaeger(Name) ->
  Cmd = io_lib:format(
    "docker run -d --name ~s "
    "-p 16686:16686 "
    "-p 4318:4318 "
    "jaegertracing/all-in-one:latest 2>&1", [Name]),
  Result = os:cmd(lists:flatten(Cmd)),
  case string:find(Result, "Error") of
    nomatch -> {ok, Name};
    _ -> {error, Result}
  end.

%% @doc Stops and removes a Docker container.
-spec stop_container(string()) -> ok.
stop_container(Name) ->
  _ = os:cmd(io_lib:format("docker stop ~s 2>&1", [Name])),
  _ = os:cmd(io_lib:format("docker rm ~s 2>&1", [Name])),
  ok.

%% @doc Waits for an HTTP endpoint to become ready.
-spec wait_for_http(binary(), pos_integer()) -> ok | {error, timeout}.
wait_for_http(Url, MaxAttempts) ->
  wait_for_http(Url, MaxAttempts, 0).

%% @doc Waits for Prometheus target to be scraped successfully.
-spec wait_for_prometheus_target(binary(), pos_integer()) -> ok | {error, timeout}.
wait_for_prometheus_target(BaseUrl, MaxAttempts) ->
  wait_for_prometheus_target(BaseUrl, MaxAttempts, 0).

wait_for_prometheus_target(_BaseUrl, MaxAttempts, Attempts) when Attempts >= MaxAttempts ->
  {error, timeout};
wait_for_prometheus_target(BaseUrl, MaxAttempts, Attempts) ->
  Url = <<BaseUrl/binary, "/api/v1/targets">>,
  case hackney:request(get, Url, [], <<>>, [with_body]) of
    {ok, 200, _, Body} ->
      Result = json:decode(Body),
      case Result of
        #{<<"data">> := #{<<"activeTargets">> := Targets}} ->
          case has_healthy_target(Targets) of
            true -> ok;
            false ->
              timer:sleep(1000),
              wait_for_prometheus_target(BaseUrl, MaxAttempts, Attempts + 1)
          end;
        _ ->
          timer:sleep(1000),
          wait_for_prometheus_target(BaseUrl, MaxAttempts, Attempts + 1)
      end;
    _ ->
      timer:sleep(1000),
      wait_for_prometheus_target(BaseUrl, MaxAttempts, Attempts + 1)
  end.

has_healthy_target([]) -> false;
has_healthy_target([#{<<"health">> := <<"up">>} | _]) -> true;
has_healthy_target([_ | Rest]) -> has_healthy_target(Rest).

wait_for_http(_Url, MaxAttempts, Attempts) when Attempts >= MaxAttempts ->
  {error, timeout};
wait_for_http(Url, MaxAttempts, Attempts) ->
  case hackney:request(get, Url, [], <<>>, [{timeout, 1000}, {connect_timeout, 1000}, with_body]) of
    {ok, Status, _, _Body} when Status >= 200, Status < 400 ->
      ok;
    {ok, _, _, _} ->
      timer:sleep(500),
      wait_for_http(Url, MaxAttempts, Attempts + 1);
    _ ->
      timer:sleep(500),
      wait_for_http(Url, MaxAttempts, Attempts + 1)
  end.

%% @doc Queries Prometheus for a metric, with retry logic.
-spec query_prometheus(binary(), binary()) -> {ok, map()} | {error, term()}.
query_prometheus(BaseUrl, MetricName) ->
  query_prometheus(BaseUrl, MetricName, 15).

-spec query_prometheus(binary(), binary(), non_neg_integer()) -> {ok, map()} | {error, term()}.
query_prometheus(_BaseUrl, _MetricName, 0) ->
  ct:pal("Prometheus query: exhausted retries"),
  {error, no_results_after_retries};
query_prometheus(BaseUrl, MetricName, Retries) ->
  Url = <<BaseUrl/binary, "/api/v1/query?query=", MetricName/binary>>,
  try
    case hackney:request(get, Url, [], <<>>, [with_body, {pool, false}]) of
      {ok, 200, _, Body} ->
        Result = json:decode(Body),
        case Result of
          #{<<"status">> := <<"success">>, <<"data">> := #{<<"result">> := []}} ->
            %% Empty results, retry after delay
            ct:pal("Prometheus query empty, retrying (~p left)", [Retries - 1]),
            timer:sleep(1000),
            query_prometheus(BaseUrl, MetricName, Retries - 1);
          _ ->
            ct:pal("Prometheus query success"),
            {ok, Result}
        end;
      {ok, Status, _, _} ->
        {error, {http_error, Status}};
      {error, Reason} ->
        ct:pal("Prometheus query error: ~p, retrying (~p left)", [Reason, Retries - 1]),
        timer:sleep(1000),
        query_prometheus(BaseUrl, MetricName, Retries - 1)
    end
  catch
    _:Err ->
      ct:pal("Prometheus query exception: ~p, retrying (~p left)", [Err, Retries - 1]),
      timer:sleep(1000),
      query_prometheus(BaseUrl, MetricName, Retries - 1)
  end.

%% @doc Queries Jaeger for traces by service name, with retry logic.
-spec query_jaeger_traces(binary(), binary()) -> {ok, map()} | {error, term()}.
query_jaeger_traces(BaseUrl, ServiceName) ->
  query_jaeger_traces(BaseUrl, ServiceName, 10).

-spec query_jaeger_traces(binary(), binary(), non_neg_integer()) -> {ok, map()} | {error, term()}.
query_jaeger_traces(_BaseUrl, _ServiceName, 0) ->
  ct:pal("Jaeger query: exhausted retries"),
  {error, no_traces_after_retries};
query_jaeger_traces(BaseUrl, ServiceName, Retries) ->
  Url = <<BaseUrl/binary, "/api/traces?service=", ServiceName/binary, "&limit=100">>,
  try
    case hackney:request(get, Url, [], <<>>, [with_body, {pool, false}]) of
      {ok, 200, _, Body} ->
        Result = json:decode(Body),
        case Result of
          #{<<"data">> := []} ->
            %% Empty traces, retry after delay
            ct:pal("Jaeger query empty, retrying (~p left)", [Retries - 1]),
            timer:sleep(1000),
            query_jaeger_traces(BaseUrl, ServiceName, Retries - 1);
          _ ->
            ct:pal("Jaeger query success"),
            {ok, Result}
        end;
      {ok, Status, _, _} ->
        {error, {http_error, Status}};
      {error, Reason} ->
        ct:pal("Jaeger query error: ~p, retrying (~p left)", [Reason, Retries - 1]),
        timer:sleep(1000),
        query_jaeger_traces(BaseUrl, ServiceName, Retries - 1)
    end
  catch
    _:Err ->
      ct:pal("Jaeger query exception: ~p, retrying (~p left)", [Err, Retries - 1]),
      timer:sleep(1000),
      query_jaeger_traces(BaseUrl, ServiceName, Retries - 1)
  end.

%% @doc Starts a simple HTTP server exposing /metrics endpoint.
-spec start_metrics_server(pos_integer()) -> {ok, pid()} | {error, term()}.
start_metrics_server(Port) ->
  Parent = self(),
  %% Use spawn instead of spawn_link to avoid process dying when init_per_group ends
  Pid = spawn(fun() ->
    process_flag(trap_exit, true),
    %% Explicitly bind to all IPv4 interfaces
    case gen_tcp:listen(Port, [binary, {active, false}, {reuseaddr, true}, {backlog, 100}, {ip, {0,0,0,0}}]) of
      {ok, LSock} ->
        Parent ! {started, self()},
        accept_loop(LSock);
      {error, Reason} ->
        Parent ! {error, Reason}
    end
  end),
  receive
    {started, Pid} -> {ok, Pid};
    {error, Reason} -> {error, Reason}
  after 5000 ->
    {error, timeout}
  end.

%% @doc Stops the metrics server.
-spec stop_metrics_server(pid()) -> ok.
stop_metrics_server(Pid) ->
  exit(Pid, shutdown),
  ok.

%% Internal functions

accept_loop(LSock) ->
  case gen_tcp:accept(LSock, 1000) of
    {ok, Sock} ->
      spawn(fun() -> handle_request(Sock) end),
      accept_loop(LSock);
    {error, timeout} ->
      accept_loop(LSock);
    {error, closed} ->
      ok;
    {error, _} ->
      accept_loop(LSock)
  end.

handle_request(Sock) ->
  case gen_tcp:recv(Sock, 0, 5000) of
    {ok, Data} ->
      case parse_request(Data) of
        {get, <<"/metrics", _/binary>>} ->
          Body = instrument_prometheus:format(),
          ContentType = instrument_prometheus:content_type(),
          BodySize = byte_size(Body),
          Response = io_lib:format(
            "HTTP/1.1 200 OK\r\n"
            "Content-Type: ~s\r\n"
            "Content-Length: ~B\r\n"
            "\r\n~s",
            [ContentType, BodySize, Body]),
          gen_tcp:send(Sock, Response);
        _ ->
          Response = "HTTP/1.1 404 Not Found\r\n"
            "Content-Length: 0\r\n\r\n",
          gen_tcp:send(Sock, Response)
      end;
    _ ->
      ok
  end,
  gen_tcp:close(Sock).

parse_request(Data) ->
  Lines = binary:split(Data, <<"\r\n">>, [global]),
  case Lines of
    [RequestLine | _] ->
      case binary:split(RequestLine, <<" ">>, [global]) of
        [<<"GET">>, Path | _] -> {get, Path};
        [<<"POST">>, Path | _] -> {post, Path};
        _ -> {unknown, <<>>}
      end;
    _ ->
      {unknown, <<>>}
  end.
