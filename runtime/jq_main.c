/* Copyright (C) 2026 Josh Winters
 * SPDX-License-Identifier: Apache-2.0
 * Additional permission applies; see ../RUNTIME-EXCEPTION.md. */

/* Program entry scaffold (task 67): compiled programs run on a dedicated
 * thread with a large stack (default 1 GiB, JACQUARD_STACK_MB overrides)
 * because deep non-tail Jacquard recursion becomes deep C recursion — the
 * interpreter's heap frames are unbounded, and a 200k-deep list.range
 * segfaults an 8 MiB main stack. Pages commit lazily; the reservation is
 * virtual. This is a recorded parity boundary (docs/native-plan.md). */

#include "jq_value.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

struct run {
  jq_rt *rt;
  void (*body)(jq_rt *);
};

static void *trampoline(void *arg) {
  struct run *r = arg;
  r->body(r->rt);
  return NULL;
}

int jq_run_main(jq_rt *rt, void (*body)(jq_rt *)) {
  size_t mb = 1024;
  const char *env = getenv("JACQUARD_STACK_MB");
  if (env) {
    long v = atol(env);
    if (v > 0) mb = (size_t)v;
  }
  pthread_attr_t attr;
  pthread_t tid;
  struct run r = { rt, body };
  if (pthread_attr_init(&attr) != 0 ||
      pthread_attr_setstacksize(&attr, mb * 1024 * 1024) != 0 ||
      pthread_create(&tid, &attr, trampoline, &r) != 0) {
    jq_runtime_fail(JQ_ERROR_NATIVE, "jacquard runtime: could not start the program thread");
  }
  pthread_join(tid, NULL);
  /* the handler and frame stacks' backing arrays outlive every balanced
     push/pop; release them here so effectful programs are leak-clean under
     the task-68 gate (entries and frames are gone: pops dropped them) */
  free(rt->hs);
  rt->hs = NULL;
  rt->hs_len = rt->hs_cap = 0;
  free(rt->ks);
  rt->ks = NULL;
  rt->ks_len = rt->ks_cap = 0;
  return 0;
}
