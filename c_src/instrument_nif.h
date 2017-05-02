/* Copyright (c) 2017, Benoit Chesneau <bchesneau@gmail.com>.
 *
 * This file is part of instrument released under the MIT license.
 * See the NOTICE for more information.
 */


#ifndef INCL_instrument_H
#define INCL_instrument_H

extern "C" {
#include "erl_nif.h"

ERL_NIF_TERM instrument_new_gauge(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM instrument_inc_gauge(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM instrument_dec_gauge(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM instrument_set_gauge(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM instrument_get_gauge(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
}

namespace instrument {

ERL_NIF_TERM NewGauge(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM IncGauge(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM DecGauge(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM SetGauge(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM GetGauge(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);

} // namespace instrument

#endif