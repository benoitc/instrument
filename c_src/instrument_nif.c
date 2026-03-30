/* Copyright (c) 2017, Benoit Chesneau <bchesneau@gmail.com>.
 *
 * This file is part of instrument released under the MIT license.
 * See the NOTICE for more information.
 */

#include "erl_nif.h"
#include "gauge.h"

static ERL_NIF_TERM ATOM_OK;
static ERL_NIF_TERM ATOM_ERROR;
static ERL_NIF_TERM ATOM_EINVAL;
static ERL_NIF_TERM ATOM_BADARG;

static ErlNifResourceType *gauge_resource_type;

static void
gauge_resource_cleanup(ErlNifEnv *env, void *res)
{
    (void)env;
    (void)res;
}

static void
create_gauge_type(ErlNifEnv *env)
{
    ErlNifResourceFlags flags = ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER;
    gauge_resource_type = enif_open_resource_type(env, NULL, "instrument_gauge",
                                                   gauge_resource_cleanup, flags, NULL);
}

static ERL_NIF_TERM
new_gauge(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    (void)argv;

    instrument_gauge_t *gauge = enif_alloc_resource(gauge_resource_type,
                                                     sizeof(instrument_gauge_t));
    if (gauge == NULL) {
        return enif_make_tuple2(env, ATOM_ERROR, ATOM_EINVAL);
    }

    instrument_gauge_init(gauge, 0.0);

    ERL_NIF_TERM result = enif_make_resource(env, gauge);
    enif_release_resource(gauge);
    return enif_make_tuple2(env, ATOM_OK, result);
}

static ERL_NIF_TERM
inc_gauge(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    instrument_gauge_t *gauge;

    if (!enif_get_resource(env, argv[0], gauge_resource_type, (void **)&gauge))
        return enif_make_badarg(env);

    if (argc > 1) {
        double v;
        if (!enif_get_double(env, argv[1], &v))
            return enif_make_badarg(env);
        instrument_gauge_inc(gauge, v);
    } else {
        instrument_gauge_inc(gauge, 1.0);
    }

    return ATOM_OK;
}

static ERL_NIF_TERM
dec_gauge(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    instrument_gauge_t *gauge;

    if (!enif_get_resource(env, argv[0], gauge_resource_type, (void **)&gauge))
        return enif_make_badarg(env);

    if (argc > 1) {
        double v;
        if (!enif_get_double(env, argv[1], &v))
            return enif_make_badarg(env);
        instrument_gauge_dec(gauge, v);
    } else {
        instrument_gauge_dec(gauge, 1.0);
    }

    return ATOM_OK;
}

static ERL_NIF_TERM
set_gauge(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    instrument_gauge_t *gauge;

    if (!enif_get_resource(env, argv[0], gauge_resource_type, (void **)&gauge))
        return enif_make_badarg(env);

    double v;
    if (!enif_get_double(env, argv[1], &v))
        return enif_make_badarg(env);

    instrument_gauge_set(gauge, v);
    return ATOM_OK;
}

static ERL_NIF_TERM
get_gauge(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    instrument_gauge_t *gauge;

    if (!enif_get_resource(env, argv[0], gauge_resource_type, (void **)&gauge))
        return enif_make_badarg(env);

    double v = instrument_gauge_value(gauge);
    return enif_make_double(env, v);
}

static ErlNifFunc nif_funcs[] = {
    {"new_gauge", 0, new_gauge, 0},
    {"inc_gauge", 1, inc_gauge, 0},
    {"inc_gauge", 2, inc_gauge, 0},
    {"dec_gauge", 1, dec_gauge, 0},
    {"dec_gauge", 2, dec_gauge, 0},
    {"set_gauge", 2, set_gauge, 0},
    {"get_gauge", 1, get_gauge, 0}
};

static void on_unload(ErlNifEnv *env, void *priv_data)
{
    (void)env;
    (void)priv_data;
}

static int on_load(ErlNifEnv* env, void** priv_data, ERL_NIF_TERM load_info)
{
    (void)priv_data;
    (void)load_info;

    create_gauge_type(env);

#define ATOM(Id, Value) { Id = enif_make_atom(env, Value); }
    ATOM(ATOM_OK, "ok");
    ATOM(ATOM_ERROR, "error");
    ATOM(ATOM_EINVAL, "einval");
    ATOM(ATOM_BADARG, "badarg");
#undef ATOM

    return 0;
}

ERL_NIF_INIT(instrument_nif, nif_funcs, &on_load, NULL, NULL, &on_unload)
