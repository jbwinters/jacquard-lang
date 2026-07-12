/* Copyright (C) 2026 Josh Winters
 * SPDX-License-Identifier: Apache-2.0
 * Additional permission applies; see ../RUNTIME-EXCEPTION.md. */

/* Generic application (task 67): the unknown-callee path. Dispatch and error
 * texts mirror the interpreter's apply (src/eval.ml); Runtime_err renderings
 * come through jq_error.c's contract (stderr + exit 2). Every input is owned:
 * the callee consumes fn and the n arguments. */

#include "jq_value.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void fail(const char *fmt, ...) __attribute__((noreturn, format(printf, 1, 2)));
static void fail(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vfprintf(stderr, fmt, ap);
  va_end(ap);
  fputc('\n', stderr);
  exit(2);
}

jq_value jq_apply(JQ_PARAMS) {
  jq_value fn = clo;
  uint16_t n = rt->apply_n;
  if (jq_is_int(fn)) {
    char *s = jq_show(fn);
    fail("type error: %s is not applicable", s);
  }
  jq_block *b = jq_block_of(fn);
  switch (b->tag) {
  case JQ_CLOSURE: {
    uint16_t arity = jq_closure_arity(fn);
    if (arity != n)
      fail("arity mismatch: closure of %u parameter(s) applied to %u argument(s)",
           arity, n);
    jq_fn code = (jq_fn)jq_closure_code(fn);
    JQ_TAIL_RETURN(code, rt, fn, a0, a1, a2, a3, a4, a5, a6, a7);
  }
  case JQ_BUILTIN: {
    const jq_builtin_info *info = (const jq_builtin_info *)b->payload[0];
    jq_value args[JQ_MAX_ARITY] = { a0, a1, a2, a3, a4, a5, a6, a7 };
    /* builtins validate their own arguments (interpreter type_err parity);
       fn is static, its drop is a no-op */
    jq_drop(fn);
    if (info->arity == UINT32_MAX) {
      if (strcmp(info->name, "text.join-variadic-v1") == 0)
        return jq_i_text_join_variadic_v1(rt, args, n);
      fail("unknown variadic builtin: %s", info->name);
    }
    if (info->arity != n)
      fail("arity mismatch: builtin %s expects %u argument(s), got %u",
           info->name, info->arity, n);
    return info->fn(rt, args);
  }
  case JQ_CONSTRUCTOR: {
    const jq_con_info *info = (const jq_con_info *)b->payload[0];
    if (info->arity != n)
      fail("arity mismatch: constructor %s expects %u argument(s), got %u",
           info->name, info->arity, n);
    jq_value args[JQ_MAX_ARITY] = { a0, a1, a2, a3, a4, a5, a6, a7 };
    jq_drop(fn);
    return jq_con(info, args);
  }
  case JQ_OP: {
    /* applying a first-class op performs it (spec: no Perform form) */
    const jq_op_info *info = (const jq_op_info *)b->payload[0];
    jq_value args[JQ_MAX_ARITY] = { a0, a1, a2, a3, a4, a5, a6, a7 };
    jq_drop(fn); /* static, no-op */
    return jq_perform(rt, info->ordinal, n, args);
  }
  case JQ_RESUME: {
    /* interpreter: rt_arity "a resumption takes exactly one argument" */
    if (n != 1) fail("arity mismatch: a resumption takes exactly one argument, got %u", n);
    jq_value r = jq_resume(rt, fn, a0);
    jq_drop(fn); /* the captured original is reusable: multi-shot */
    return r;
  }
  default: {
    char *s = jq_show(fn);
    fail("type error: %s is not applicable", s);
  }
  }
}

void jq_match_fail(jq_rt *rt, jq_value scrutinee) {
  (void)rt;
  char *s = jq_show(scrutinee);
  fail("no clause matched the value %s", s);
}
