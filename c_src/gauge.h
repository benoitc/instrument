/* Copyright (c) 2017, Benoit Chesneau <bchesneau@gmail.com>.
 *
 * This file is part of instrument released under the MIT license.
 * See the NOTICE for more information.
 */

#pragma once

#include <stdatomic.h>

typedef struct {
    _Atomic double value;
} instrument_gauge_t;

void instrument_gauge_init(instrument_gauge_t *g, double value);
void instrument_gauge_inc(instrument_gauge_t *g, double value);
void instrument_gauge_dec(instrument_gauge_t *g, double value);
void instrument_gauge_set(instrument_gauge_t *g, double value);
double instrument_gauge_value(const instrument_gauge_t *g);
