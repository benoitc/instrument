/* Copyright (c) 2017, Benoit Chesneau <bchesneau@gmail.com>.
 *
 * This file is part of instrument released under the MIT license.
 * See the NOTICE for more information.
 */

#include "gauge.h"

namespace instrument {

Gauge::Gauge() : value_{0} {}

Gauge::Gauge(double value) : value_{value} {}

void Gauge::Increment() { Increment(1.0); }
void Gauge::Increment(double value) {
  if (value < 0.0) {
    return;
  }
  Change(value);
}

void Gauge::Decrement() { Decrement(1.0); }

void Gauge::Decrement(double value) {
  if (value < 0.0) {
    return;
  }
  Change(-1.0 * value);
}

void Gauge::Set(double value) { value_.store(value); }

void Gauge::Change(double value) {
  auto current = value_.load();
  while (!value_.compare_exchange_weak(current, current + value))
    ;
}

double Gauge::Value() const { return value_; }

}