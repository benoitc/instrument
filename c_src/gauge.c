/* Copyright (c) 2017, Benoit Chesneau <bchesneau@gmail.com>.
 *
 * This file is part of instrument released under the MIT license.
 * See the NOTICE for more information.
 */

#include "gauge.h"
#include <float.h>
#include <math.h>

/* Saturate instead of overflowing: an infinite value cannot be returned to
 * Erlang (enif_make_double rejects it), which would make every read fail. */
static void instrument_gauge_change(instrument_gauge_t *g, double delta) {
    double current = atomic_load(&g->value);
    double next;
    do {
        next = current + delta;
        if (!isfinite(next)) {
            next = (next > 0) ? DBL_MAX : -DBL_MAX;
        }
    } while (!atomic_compare_exchange_weak(&g->value, &current, next));
}

void instrument_gauge_init(instrument_gauge_t *g, double value) {
    atomic_init(&g->value, value);
}

void instrument_gauge_inc(instrument_gauge_t *g, double value) {
    if (value < 0.0) {
        return;
    }
    instrument_gauge_change(g, value);
}

void instrument_gauge_dec(instrument_gauge_t *g, double value) {
    if (value < 0.0) {
        return;
    }
    instrument_gauge_change(g, -value);
}

void instrument_gauge_set(instrument_gauge_t *g, double value) {
    atomic_store(&g->value, value);
}

double instrument_gauge_value(const instrument_gauge_t *g) {
    return atomic_load(&g->value);
}
