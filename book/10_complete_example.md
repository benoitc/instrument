# Putting It All Together

This chapter brings together everything you have learned to build a complete instrumented service.

## The Application

We will build an order processing service with:

- HTTP API for creating orders
- Database operations
- External payment service integration
- Background order processing

## Project Structure

```
order_service/
├── rebar.config
├── config/
│   └── sys.config
├── src/
│   ├── order_service_app.erl
│   ├── order_service_sup.erl
│   ├── order_service_telemetry.erl
│   ├── order_service_http.erl
│   ├── order_service_handler.erl
│   ├── order_service_db.erl
│   └── order_service_payment.erl
└── priv/
    └── schema.sql
```

## Dependencies

```erlang
%% rebar.config
{deps, [
    {instrument, "0.3.0"},
    {cowboy, "2.10.0"},
    {hackney, "1.20.1"},
    {jiffy, "1.1.1"}
]}.
```

## Configuration

```erlang
%% config/sys.config
[
    {order_service, [
        {http_port, 8080},
        {db_pool_size, 10},
        {payment_service_url, "http://payment-service:8080"}
    ]},
    {instrument, [
        {service_name, <<"order-service">>}
    ]}
].
```

## Telemetry Setup

```erlang
%% src/order_service_telemetry.erl
-module(order_service_telemetry).
-export([init/0]).

init() ->
    %% Initialize from environment
    instrument_config:init(),

    %% Create metrics
    create_metrics(),

    %% Set up span processor
    setup_tracing(),

    %% Set up logging
    setup_logging(),

    ok.

create_metrics() ->
    %% HTTP metrics
    instrument_metric:new_counter_vec(
        http_requests_total,
        <<"Total HTTP requests">>,
        [method, status, endpoint]
    ),
    instrument_metric:new_histogram_vec(
        http_request_duration_seconds,
        <<"HTTP request duration">>,
        [method, endpoint]
    ),
    instrument_metric:new_gauge(
        http_active_requests,
        <<"Currently active HTTP requests">>
    ),

    %% Database metrics
    instrument_metric:new_counter_vec(
        db_queries_total,
        <<"Total database queries">>,
        [operation]
    ),
    instrument_metric:new_histogram_vec(
        db_query_duration_seconds,
        <<"Database query duration">>,
        [operation]
    ),
    instrument_metric:new_gauge(
        db_pool_connections_active,
        <<"Active database connections">>
    ),

    %% Business metrics
    instrument_metric:new_counter_vec(
        orders_total,
        <<"Total orders">>,
        [status]
    ),
    instrument_metric:new_histogram(
        order_value_dollars,
        <<"Order value distribution">>,
        [10, 25, 50, 100, 250, 500, 1000]
    ),

    ok.

setup_tracing() ->
    case os:getenv("OTEL_EXPORTER_OTLP_ENDPOINT") of
        false ->
            %% Development: console export
            instrument_tracer:register_exporter(
                fun(Span) -> instrument_exporter_console:export(Span) end
            );
        Endpoint ->
            %% Production: batch OTLP export
            {ok, _} = instrument_span_processor_batch:start_link(#{
                exporter => instrument_exporter_otlp:new(#{
                    endpoint => Endpoint ++ "/v1/traces"
                }),
                max_queue_size => 2048,
                scheduled_delay => 5000,
                max_export_batch_size => 512
            })
    end,
    ok.

setup_logging() ->
    case os:getenv("OTEL_EXPORTER_OTLP_ENDPOINT") of
        false ->
            %% Just add trace context to logs
            instrument_logger:install();
        Endpoint ->
            %% Export logs via OTLP
            LogExporter = instrument_log_exporter_otlp:new(#{
                endpoint => Endpoint ++ "/v1/logs"
            }),
            instrument_log_exporter:register(LogExporter),
            instrument_logger:install(#{exporter => true})
    end,
    ok.
```

## HTTP Handler

```erlang
%% src/order_service_http.erl
-module(order_service_http).
-export([init/2]).

init(Req0, State) ->
    %% Extract trace context from headers
    Headers = cowboy_req:headers(Req0),
    Ctx = instrument_propagation:extract_headers(maps:to_list(Headers)),
    Token = instrument_context:attach(Ctx),

    %% Track active requests
    instrument_metric:inc_gauge(http_active_requests),

    Method = cowboy_req:method(Req0),
    Path = cowboy_req:path(Req0),

    try
        instrument_tracer:with_span(<<"http_request">>, #{kind => server}, fun() ->
            instrument_tracer:set_attributes(#{
                <<"http.method">> => Method,
                <<"http.target">> => Path,
                <<"http.scheme">> => <<"http">>
            }),

            %% Route and handle
            Start = erlang:monotonic_time(microsecond),
            {Status, RespHeaders, Body} = route(Method, Path, Req0),
            Duration = (erlang:monotonic_time(microsecond) - Start) / 1000000,

            %% Record metrics
            Endpoint = normalize_path(Path),
            instrument_metric:inc_counter_vec(http_requests_total, [Method, integer_to_binary(Status), Endpoint]),
            instrument_metric:observe_histogram_vec(http_request_duration_seconds, [Method, Endpoint], Duration),

            %% Set span attributes
            instrument_tracer:set_attribute(<<"http.status_code">>, Status),
            case Status >= 400 of
                true -> instrument_tracer:set_status(error);
                false -> instrument_tracer:set_status(ok)
            end,

            Req = cowboy_req:reply(Status, RespHeaders, Body, Req0),
            {ok, Req, State}
        end)
    after
        instrument_metric:dec_gauge(http_active_requests),
        instrument_context:detach(Token)
    end.

route(<<"POST">>, <<"/orders">>, Req) ->
    order_service_handler:create_order(Req);
route(<<"GET">>, <<"/orders/", OrderId/binary>>, _Req) ->
    order_service_handler:get_order(OrderId);
route(<<"GET">>, <<"/health">>, _Req) ->
    {200, #{}, <<"{\"status\":\"ok\"}">>};
route(<<"GET">>, <<"/metrics">>, _Req) ->
    Body = instrument_prometheus:format(),
    {200, #{<<"content-type">> => instrument_prometheus:content_type()}, Body};
route(_, _, _) ->
    {404, #{}, <<"{\"error\":\"not_found\"}">>}.

normalize_path(<<"/orders/", _/binary>>) -> <<"/orders/{id}">>;
normalize_path(Path) -> Path.
```

## Order Handler

```erlang
%% src/order_service_handler.erl
-module(order_service_handler).
-export([create_order/1, get_order/1]).

create_order(Req) ->
    instrument_tracer:with_span(<<"create_order">>, fun() ->
        {ok, Body, _} = cowboy_req:read_body(Req),
        Order = jiffy:decode(Body, [return_maps]),

        OrderId = generate_order_id(),
        instrument_tracer:set_attributes(#{
            <<"order.id">> => OrderId,
            <<"order.items">> => length(maps:get(<<"items">>, Order, []))
        }),

        logger:info("Creating order", #{order_id => OrderId}),

        %% Validate order
        case validate_order(Order) of
            {error, Reason} ->
                logger:warning("Order validation failed: ~p", [Reason]),
                instrument_tracer:set_status(error, <<"Validation failed">>),
                instrument_metric:inc_counter_vec(orders_total, [<<"validation_failed">>]),
                {400, #{}, jiffy:encode(#{error => Reason})};

            ok ->
                instrument_tracer:add_event(<<"order_validated">>),

                %% Calculate total
                Total = calculate_total(Order),
                instrument_tracer:set_attribute(<<"order.total">>, Total),
                instrument_metric:observe_histogram(order_value_dollars, Total),

                %% Process payment
                case process_payment(OrderId, Total, Order) of
                    {ok, PaymentId} ->
                        instrument_tracer:add_event(<<"payment_completed">>, #{
                            <<"payment.id">> => PaymentId
                        }),

                        %% Save order
                        case save_order(OrderId, Order, PaymentId) of
                            ok ->
                                logger:info("Order created successfully"),
                                instrument_tracer:set_status(ok),
                                instrument_metric:inc_counter_vec(orders_total, [<<"completed">>]),
                                {201, #{}, jiffy:encode(#{
                                    order_id => OrderId,
                                    payment_id => PaymentId,
                                    total => Total
                                })};

                            {error, DbError} ->
                                logger:error("Failed to save order: ~p", [DbError]),
                                instrument_tracer:record_exception(DbError),
                                instrument_tracer:set_status(error, <<"Database error">>),
                                instrument_metric:inc_counter_vec(orders_total, [<<"db_error">>]),
                                {500, #{}, jiffy:encode(#{error => <<"internal_error">>})}
                        end;

                    {error, PaymentError} ->
                        logger:warning("Payment failed: ~p", [PaymentError]),
                        instrument_tracer:set_status(error, <<"Payment failed">>),
                        instrument_metric:inc_counter_vec(orders_total, [<<"payment_failed">>]),
                        {402, #{}, jiffy:encode(#{error => <<"payment_failed">>})}
                end
        end
    end).

get_order(OrderId) ->
    instrument_tracer:with_span(<<"get_order">>, fun() ->
        instrument_tracer:set_attribute(<<"order.id">>, OrderId),

        case order_service_db:get_order(OrderId) of
            {ok, Order} ->
                instrument_tracer:set_status(ok),
                {200, #{}, jiffy:encode(Order)};
            {error, not_found} ->
                instrument_tracer:set_status(error, <<"Not found">>),
                {404, #{}, jiffy:encode(#{error => <<"not_found">>})}
        end
    end).

validate_order(Order) ->
    instrument_tracer:with_span(<<"validate_order">>, fun() ->
        Items = maps:get(<<"items">>, Order, []),
        case Items of
            [] -> {error, <<"no_items">>};
            _ -> ok
        end
    end).

calculate_total(Order) ->
    Items = maps:get(<<"items">>, Order, []),
    lists:foldl(fun(Item, Acc) ->
        Price = maps:get(<<"price">>, Item, 0),
        Qty = maps:get(<<"quantity">>, Item, 1),
        Acc + (Price * Qty)
    end, 0, Items).

process_payment(OrderId, Total, Order) ->
    order_service_payment:charge(OrderId, Total, Order).

save_order(OrderId, Order, PaymentId) ->
    order_service_db:insert_order(OrderId, Order, PaymentId).

generate_order_id() ->
    list_to_binary(uuid:to_string(uuid:v4())).
```

## Database Layer

```erlang
%% src/order_service_db.erl
-module(order_service_db).
-export([insert_order/3, get_order/1]).

insert_order(OrderId, Order, PaymentId) ->
    instrument_tracer:with_span(<<"db_insert_order">>, #{kind => client}, fun() ->
        instrument_tracer:set_attributes(#{
            <<"db.system">> => <<"postgresql">>,
            <<"db.operation">> => <<"INSERT">>,
            <<"db.table">> => <<"orders">>
        }),

        Start = erlang:monotonic_time(microsecond),

        %% Simulated database insert
        Result = do_insert(OrderId, Order, PaymentId),

        Duration = (erlang:monotonic_time(microsecond) - Start) / 1000000,
        instrument_metric:inc_counter_vec(db_queries_total, [<<"INSERT">>]),
        instrument_metric:observe_histogram_vec(db_query_duration_seconds, [<<"INSERT">>], Duration),

        case Result of
            ok ->
                instrument_tracer:set_status(ok),
                ok;
            {error, _} = Err ->
                instrument_tracer:set_status(error),
                Err
        end
    end).

get_order(OrderId) ->
    instrument_tracer:with_span(<<"db_get_order">>, #{kind => client}, fun() ->
        instrument_tracer:set_attributes(#{
            <<"db.system">> => <<"postgresql">>,
            <<"db.operation">> => <<"SELECT">>,
            <<"db.table">> => <<"orders">>
        }),

        Start = erlang:monotonic_time(microsecond),

        %% Simulated database query
        Result = do_select(OrderId),

        Duration = (erlang:monotonic_time(microsecond) - Start) / 1000000,
        instrument_metric:inc_counter_vec(db_queries_total, [<<"SELECT">>]),
        instrument_metric:observe_histogram_vec(db_query_duration_seconds, [<<"SELECT">>], Duration),

        Result
    end).

%% Simulated database operations
do_insert(_OrderId, _Order, _PaymentId) ->
    timer:sleep(10), %% Simulate latency
    ok.

do_select(_OrderId) ->
    timer:sleep(5),
    {ok, #{id => <<"test">>, items => [], total => 0}}.
```

## Payment Integration

```erlang
%% src/order_service_payment.erl
-module(order_service_payment).
-export([charge/3]).

charge(OrderId, Amount, Order) ->
    instrument_tracer:with_span(<<"payment_charge">>, #{kind => client}, fun() ->
        instrument_tracer:set_attributes(#{
            <<"payment.amount">> => Amount,
            <<"payment.currency">> => <<"USD">>
        }),

        %% Inject trace context into outgoing request
        Ctx = instrument_context:current(),
        Headers = instrument_propagation:inject_headers(Ctx),

        URL = get_payment_url(),
        Body = jiffy:encode(#{
            order_id => OrderId,
            amount => Amount,
            currency => <<"USD">>,
            customer => maps:get(<<"customer">>, Order, #{})
        }),

        logger:debug("Calling payment service", #{url => URL}),

        case hackney:request(post, URL, Headers, Body, [{recv_timeout, 30000}]) of
            {ok, 200, _RespHeaders, ClientRef} ->
                {ok, RespBody} = hackney:body(ClientRef),
                Response = jiffy:decode(RespBody, [return_maps]),
                PaymentId = maps:get(<<"payment_id">>, Response),
                instrument_tracer:set_attributes(#{
                    <<"http.status_code">> => 200,
                    <<"payment.id">> => PaymentId
                }),
                instrument_tracer:set_status(ok),
                {ok, PaymentId};

            {ok, Status, _RespHeaders, ClientRef} ->
                {ok, RespBody} = hackney:body(ClientRef),
                logger:warning("Payment failed with status ~p: ~s", [Status, RespBody]),
                instrument_tracer:set_attributes(#{
                    <<"http.status_code">> => Status
                }),
                instrument_tracer:set_status(error, <<"Payment declined">>),
                {error, declined};

            {error, Reason} ->
                logger:error("Payment service error: ~p", [Reason]),
                instrument_tracer:record_exception(Reason),
                instrument_tracer:set_status(error, <<"Payment service unavailable">>),
                {error, service_unavailable}
        end
    end).

get_payment_url() ->
    BaseUrl = application:get_env(order_service, payment_service_url, "http://localhost:8081"),
    BaseUrl ++ "/charge".
```

## Running the Service

```bash
# Start dependencies
docker-compose up -d jaeger prometheus

# Set environment
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
export OTEL_SERVICE_NAME=order-service
export OTEL_TRACES_SAMPLER=parentbased_traceidratio
export OTEL_TRACES_SAMPLER_ARG=0.5

# Run the service
rebar3 shell
```

## Testing

```bash
# Create an order
curl -X POST http://localhost:8080/orders \
  -H "Content-Type: application/json" \
  -d '{"items": [{"name": "Widget", "price": 29.99, "quantity": 2}]}'

# Get metrics
curl http://localhost:8080/metrics

# View traces
open http://localhost:16686
```

## What You Built

You now have a service with:

- Request tracing across HTTP and database calls
- Distributed trace propagation to external services
- Metrics for requests, latencies, and business events
- Correlated logs with trace context
- Prometheus metrics endpoint
- OTLP export to Jaeger

## Next Steps

- Add more business metrics specific to your domain
- Implement custom sampling based on your needs
- Set up alerting on key metrics
- Create dashboards in Grafana
- Add SLO monitoring

Congratulations on completing this handbook!
