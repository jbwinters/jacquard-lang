/* The effects runtime (docs/native-plan.md, task 70): a per-run handler
 * stack with nearest-match perform, and the interpreter's exact contracts.
 *
 * The parity subtlety: an op CLAUSE BODY runs against the continuation
 * OUTSIDE its handler (src/eval.ml's perform runs obody with the outer
 * frames), so re-performs from inside a clause must not see the matched
 * handler or anything above it. jq_perform therefore hides the stack slice
 * [match .. top] for the duration of the clause call and restores it after
 * — a new handle pushed inside the clause lands at the truncation point and
 * is popped before the clause returns (push/pop are structured). */

#include "jq_value.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void grow(jq_rt *rt, uint32_t need) {
  if (rt->hs_len + need > rt->hs_cap) {
    rt->hs_cap = rt->hs_cap ? rt->hs_cap * 2 : 16;
    if (rt->hs_cap < rt->hs_len + need) rt->hs_cap = rt->hs_len + need;
    rt->hs = realloc(rt->hs, rt->hs_cap * sizeof(jq_handler_entry));
    if (!rt->hs) jq_runtime_error("jacquard runtime: out of memory");
  }
}

void jq_handle_push(jq_rt *rt, uint32_t n, const jq_handler_entry *entries) {
  grow(rt, n);
  memcpy(&rt->hs[rt->hs_len], entries, n * sizeof(jq_handler_entry));
  rt->hs_len += n;
}

void jq_handle_pop(jq_rt *rt, uint32_t n) {
  for (uint32_t i = 0; i < n; i++) jq_drop(rt->hs[rt->hs_len - 1 - i].clause);
  rt->hs_len -= n;
}

jq_value jq_perform(jq_rt *rt, uint32_t op_ord, uint16_t n, const jq_value *args) {
  /* nearest in-language handler wins */
  for (uint32_t i = rt->hs_len; i > 0; i--) {
    if (rt->hs[i - 1].op_ord != op_ord) continue;
    uint32_t at = i - 1;
    jq_value clause = rt->hs[at].clause;
    jq_dup(clause); /* the call consumes clo; the stack entry keeps its ref */
    /* hide [at .. top] for the clause body (outer-continuation semantics) */
    uint32_t hidden = rt->hs_len - at;
    jq_handler_entry *save = malloc(hidden * sizeof(jq_handler_entry));
    if (!save) jq_runtime_error("jacquard runtime: out of memory");
    memcpy(save, &rt->hs[at], hidden * sizeof(jq_handler_entry));
    rt->hs_len = at;
    jq_fn code = (jq_fn)jq_closure_code(clause);
    jq_value a[JQ_MAX_ARITY] = { 0 };
    for (uint16_t k = 0; k < n; k++) a[k] = args[k];
    for (uint16_t k = n; k < JQ_MAX_ARITY; k++) a[k] = JQ_UNIT;
    jq_value r = code(rt, clause, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7]);
    grow(rt, hidden);
    memcpy(&rt->hs[rt->hs_len], save, hidden * sizeof(jq_handler_entry));
    rt->hs_len += hidden;
    free(save);
    return r;
  }
  /* root grants (the --allow natives) */
  if (op_ord < rt->n_ops && rt->grants && rt->grants[op_ord])
    return rt->grants[op_ord](rt, args);
  /* the capability story at runtime: unhandled dies, exit 3 */
  const jq_op_info *info = op_ord < rt->n_ops ? rt->op_meta[op_ord] : NULL;
  fprintf(stderr,
          "unhandled effect %s: operation `%s` reached the root without a handler\n",
          info ? info->effect_name : "?", info ? info->op_name : "?");
  exit(3);
}
