/* Copyright (c) 2017, Benoit Chesneau <bchesneau@gmail.com>.
 *
 * This file is part of instrument released under the MIT license.
 * See the NOTICE for more information.
 */

#include <syslog.h>

#include <new>
#include <stdexcept>

#include "instrument_nif.h"

#include "erl_nif.h"

#ifndef ATOMS_H
#include "atoms.h"
#endif

#include "gauge.h"


static ErlNifFunc nif_funcs[] =
{
    {"new_gauge", 0, instrument::NewGauge},
    {"inc_gauge", 1, instrument::IncGauge},
    {"inc_gauge", 2, instrument::IncGauge},
    {"dec_gauge", 1, instrument::DecGauge},
    {"dec_gauge", 2, instrument::DecGauge},
    {"set_gauge", 2, instrument::SetGauge},
    {"get_gauge", 1, instrument::GetGauge}
};

namespace instrument {

    ERL_NIF_TERM ATOM_OK;
    ERL_NIF_TERM ATOM_ERROR;
    ERL_NIF_TERM ATOM_EINVAL;
    ERL_NIF_TERM ATOM_BADARG;

    
    ErlNifResourceType *m_Gauge_RESOURCE;

    void
    gauge_resource_cleanup(ErlNifEnv *env, void *res)
    {

    }

    void
    CreateGaugeType(ErlNifEnv *env)
    {
        ErlNifResourceFlags flags = (ErlNifResourceFlags)(ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER);
        m_Gauge_RESOURCE = enif_open_resource_type(env, NULL, "instrument_Gauge", gauge_resource_cleanup, flags, NULL);
        return;
    }

    ERL_NIF_TERM
    NewGauge(
        ErlNifEnv* env,
        int argc,
        const ERL_NIF_TERM argv[])
    {
        instrument::Gauge * gauge;
        void *alloc_ptr;
        alloc_ptr = enif_alloc_resource(m_Gauge_RESOURCE, sizeof(instrument::Gauge));
        gauge = new(alloc_ptr) instrument::Gauge();
        ERL_NIF_TERM result = enif_make_resource(env, gauge);
        enif_release_resource(gauge);
        return enif_make_tuple2(env, ATOM_OK, result);
    }

    ERL_NIF_TERM
    IncGauge(
        ErlNifEnv* env,
        int argc,
        const ERL_NIF_TERM argv[])
    {
        instrument::Gauge* gauge_ptr;

        if(!enif_get_resource(env, argv[0], m_Gauge_RESOURCE, (void **) &gauge_ptr))
            return enif_make_badarg(env);

        if(argc > 1)
        {
            double v;
            if (!enif_get_double(env, argv[1], &v))
                return enif_make_badarg(env);    
            gauge_ptr->Increment(v);
        }
        else
        {
            gauge_ptr->Increment();
        }

        return ATOM_OK;
    }

    ERL_NIF_TERM
    DecGauge(
        ErlNifEnv* env,
        int argc,
        const ERL_NIF_TERM argv[])
    {
        instrument::Gauge* gauge_ptr;

        if(!enif_get_resource(env, argv[0], m_Gauge_RESOURCE, (void **) &gauge_ptr))
            return enif_make_badarg(env);

        if(argc > 1)
        {
            double v;
            if (!enif_get_double(env, argv[1], &v))
                return enif_make_badarg(env);    
            gauge_ptr->Decrement(v);
        }
        else
        {
            gauge_ptr->Decrement();
        }

        return ATOM_OK;
    }

    ERL_NIF_TERM
    SetGauge(
        ErlNifEnv* env,
        int argc,
        const ERL_NIF_TERM argv[])
    {
        instrument::Gauge* gauge_ptr;

        if(!enif_get_resource(env, argv[0], m_Gauge_RESOURCE, (void **) &gauge_ptr))
            return enif_make_badarg(env);

        double v;
        if (!enif_get_double(env, argv[1], &v))
            return enif_make_badarg(env);    
        gauge_ptr->Set(v);

        return ATOM_OK;
    }

    ERL_NIF_TERM
    GetGauge(
        ErlNifEnv* env,
        int argc,
        const ERL_NIF_TERM argv[])
    {
        instrument::Gauge* gauge_ptr;

        if(!enif_get_resource(env, argv[0], m_Gauge_RESOURCE, (void **) &gauge_ptr))
            return enif_make_badarg(env);

        double v;
        v = gauge_ptr->Value();
        return enif_make_double(env, v);
    }
    
} // namespace instrument


/*nif initialization  */

static void on_unload(ErlNifEnv *env, void *priv_data)
{
}


static int on_load(ErlNifEnv* env, void** priv_data, ERL_NIF_TERM load_info)
{
    try
    {
        instrument::CreateGaugeType(env);

#define ATOM(Id, Value) { Id = enif_make_atom(env, Value); }
        // initialize the atoms
        ATOM(instrument::ATOM_OK, "ok");
        ATOM(instrument::ATOM_ERROR, "error");
        ATOM(instrument::ATOM_EINVAL, "einval");
        ATOM(instrument::ATOM_BADARG, "badarg");
#undef ATOM

        return 0;
        
    }
    catch(...)
    {
    return -1;
    }
}

extern "C" {
    ERL_NIF_INIT(instrument_nif, nif_funcs, &on_load, NULL, NULL, &on_unload);
}
