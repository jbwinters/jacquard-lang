/* Copyright (C) 2026 Josh Winters
 * SPDX-License-Identifier: AGPL-3.0-or-later
 * Additional permission applies; see ../RUNTIME-EXCEPTION.md. */

/* Capturing continuations (docs/native-plan.md, task 71).
 *
 * The mechanism is return-unwinding: when jq_perform matches a CAPTURING
 * clause it records the pending capture in rt->pending and returns the
 * JQ_SUSPEND sentinel; every frame-style activation between the perform and
 * the covering handle propagates it, leaving its heap frame linked on
 * rt->ks (the frame stack, innermost on top — the runtime image of the
 * interpreter's kont). The covering jq_handle2 dispatch slices rt->ks from
 * its handler frame to the top into a JQ_RESUME block and runs the clause
 * against the OUTER continuation — the interpreter's exact protocol
 * (src/eval.ml perform: obody runs under `outer`, resume = the slice
 * INCLUDING the handler frame, deep semantics).
 *
 * Resume is copy-on-resume: applying a resumption clones every captured
 * frame (dup'ing each owned slot — the dup-on-capture rule from
 * docs/native-compilation.md phase 3) and re-runs the clone, so the
 * captured original stays immutable and a second resume starts from the
 * same state. The clone chain re-runs with proper C nesting (run_from
 * recurses outermost-first), so handler entries push/pop structurally and
 * nested captures during a resumed extent reuse this same file's protocol.
 *
 * Ownership: a frame's slots mirror the C locals (borrowed) while its
 * activation is live; the activation abandons them to the frame by
 * returning JQ_SUSPEND, so slices take ownership without touching a
 * count. Dropping a JQ_RESUME drops its frames, each frame its slots —
 * an aborting clause that never resumes leaks nothing. */

#include "jq_value.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

jq_block jq_suspend_block = { JQ_RC_STATIC, JQ_FRAME, 0, 0, {} };
jq_block jq_tailcall_block = { JQ_RC_STATIC, JQ_FRAME, 0, 0, {} };

/* the trampoline (task 83). Stash returns the sentinel; drive loops the
   chain flat. Under musttail toolchains JQ_HOP is identity and compiled
   code never stashes, but the runtime always drives its own call results —
   the loop body never runs there, one compare per call. */
jq_value jq_tc_stash(jq_rt *rt, jq_fn f, jq_value clo, const jq_value *args) {
  rt->tc_fn = (void *)f;
  rt->tc_clo = clo;
  for (int i = 0; i < 8; i++) rt->tc_args[i] = args[i];
  return JQ_TAILCALL;
}

jq_value jq_tc_drive(jq_rt *rt, jq_value v) {
  while (v == JQ_TAILCALL) {
    jq_fn f = (jq_fn)rt->tc_fn;
    jq_value c = rt->tc_clo;
    jq_value a0 = rt->tc_args[0], a1 = rt->tc_args[1], a2 = rt->tc_args[2],
             a3 = rt->tc_args[3], a4 = rt->tc_args[4], a5 = rt->tc_args[5],
             a6 = rt->tc_args[6], a7 = rt->tc_args[7];
    v = f(rt, c, a0, a1, a2, a3, a4, a5, a6, a7);
  }
  return v;
}

/* HF frames mark handle sites in the chain; never re-entered through code
   (run_from and jq_dispatch special-case them by this marker) */
static jq_value jq_hf_marker(jq_rt *rt, jq_block *f, jq_value v) {
  (void)rt;
  (void)f;
  (void)v;
  fputs("jacquard runtime: handler frame re-entered as code (internal)\n", stderr);
  exit(2);
}

static bool is_hf(jq_block *f) { return jq_frame_code(f) == (jq_frame_fn)jq_hf_marker; }

jq_block *jq_frame_alloc(jq_frame_fn code, uint64_t ix, uint64_t aux, uint16_t n_slots) {
  jq_block *f = jq_alloc_block(JQ_FRAME, 0, (uint16_t)(3 + n_slots));
  f->payload[0] = (uint64_t)code;
  f->payload[1] = ix;
  f->payload[2] = aux;
  return f;
}

void jq_ks_push(jq_rt *rt, jq_block *f) {
  if (rt->ks_len == rt->ks_cap) {
    rt->ks_cap = rt->ks_cap ? rt->ks_cap * 2 : 16;
    rt->ks = realloc(rt->ks, rt->ks_cap * sizeof(jq_block *));
    if (!rt->ks) jq_runtime_error("jacquard runtime: out of memory");
  }
  rt->ks[rt->ks_len++] = f;
}

/* uniform call into user code (clauses, thunks, ret): jq_apply dispatches
   on the callee tag with the interpreter's error texts */
static jq_value call_n(jq_rt *rt, jq_value fn, uint16_t n, const jq_value *args) {
  jq_value a[JQ_MAX_ARITY] = { 0 };
  for (uint16_t i = 0; i < n; i++) a[i] = args[i];
  for (uint16_t i = n; i < JQ_MAX_ARITY; i++) a[i] = JQ_UNIT;
  rt->apply_n = n;
  return jq_tc_drive(rt, jq_apply(rt, fn, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7]));
}

/* HF slot layout: [0] ret clause; then per entry [1+2i] jq_int(ord<<1|kind),
   [2+2i] clause. aux = entry count. */

static void push_entries_of(jq_rt *rt, jq_block *hf) {
  uint32_t n = (uint32_t)jq_frame_aux(hf);
  jq_value *slots = jq_frame_slots(hf);
  jq_handler_entry es[JQ_MAX_ARITY * 2]; /* entry count is small; guarded below */
  if (n > sizeof es / sizeof es[0])
    jq_runtime_error("jacquard runtime: handler clause count exceeds the limit");
  for (uint32_t i = 0; i < n; i++) {
    uint64_t word = (uint64_t)jq_int_val(slots[1 + 2 * i]);
    jq_value clause = slots[2 + 2 * i];
    jq_dup(clause); /* hs takes its own ref; hf keeps its copy for re-installs */
    es[i] = (jq_handler_entry){ .op_ord = (uint32_t)(word >> 1),
                                .clause = clause,
                                .kind = (uint8_t)(word & 1),
                                .hf = hf };
  }
  jq_handle_push(rt, n, es);
}

/* the shared dispatch: [hf] is on rt->ks with its entries pushed; [v] is
   the handled body's result or JQ_SUSPEND. Consumes hf's stack presence
   per arm; hf's heap block is consumed only on normal completion (capture
   moves it into the resumption; propagation leaves it for the outer slice). */
static jq_value jq_dispatch(jq_rt *rt, jq_block *hf, jq_value v) {
  uint32_t n_entries = (uint32_t)jq_frame_aux(hf);
  if (v == JQ_SUSPEND) {
    if (rt->pending.mark != hf) {
      /* an outer handler's capture passes through: my entries pop (they
         re-install on resume via this hf, which stays in the slice) */
      jq_handle_pop(rt, n_entries);
      return JQ_SUSPEND;
    }
    /* my clause captured: consume the pending record */
    jq_value clause = rt->pending.clause;
    uint16_t na = rt->pending.n_args;
    jq_value args[JQ_MAX_ARITY];
    for (uint16_t i = 0; i < na; i++) args[i] = rt->pending.args[i];
    rt->pending.mark = NULL;
    rt->pending.clause = 0;
    /* the clause runs against the OUTER continuation: entries off, slice
       [hf .. top] off the stack and into the resumption (hf included:
       deep handlers — the resumption re-installs the handler) */
    jq_handle_pop(rt, n_entries);
    uint32_t at = rt->ks_len;
    while (at > 0 && rt->ks[at - 1] != hf) at--;
    if (at == 0) jq_runtime_error("jacquard runtime: capture lost its handler frame (internal)");
    uint32_t cnt = rt->ks_len - (at - 1);
    jq_block *res = jq_alloc_block(JQ_RESUME, 0, (uint16_t)(1 + cnt));
    res->payload[0] = cnt;
    for (uint32_t i = 0; i < cnt; i++) res->payload[1 + i] = (uint64_t)rt->ks[at - 1 + i];
    rt->ks_len = at - 1;
    if (na + 1 > JQ_MAX_ARITY)
      jq_runtime_error("jacquard runtime: op arity exceeds the resumption slot (internal)");
    args[na] = jq_of_block(res);
    /* the clause value (or a further suspension) IS the handle's result:
       the ret clause does not run for an abandoned continuation */
    return call_n(rt, clause, (uint16_t)(na + 1), args);
  }
  /* body completed normally: hf is the top frame; ret runs OUTSIDE the
     handled region (entries popped first), per resumption or completion */
  jq_handle_pop(rt, n_entries);
  if (rt->ks_len == 0 || rt->ks[rt->ks_len - 1] != hf)
    jq_runtime_error("jacquard runtime: handle dispatch lost its frame (internal)");
  jq_ks_pop(rt);
  jq_value ret = jq_frame_slots(hf)[0];
  jq_dup(ret);
  jq_drop(jq_of_block(hf));
  jq_value rv = call_n(rt, ret, 1, &v);
  return rv;
}

jq_value jq_handle2(jq_rt *rt, uint32_t n, const jq_handler_entry *entries, jq_value thunk,
                    jq_value ret_clause) {
  jq_block *hf = jq_frame_alloc((jq_frame_fn)jq_hf_marker, 0, n, (uint16_t)(1 + 2 * n));
  jq_value *slots = jq_frame_slots(hf);
  slots[0] = ret_clause; /* ownership transfers in */
  for (uint32_t i = 0; i < n; i++) {
    slots[1 + 2 * i] = jq_int((int64_t)((uint64_t)entries[i].op_ord << 1 | entries[i].kind));
    slots[2 + 2 * i] = entries[i].clause; /* ownership transfers in */
  }
  jq_ks_push(rt, hf);
  push_entries_of(rt, hf);
  jq_value v = call_n(rt, thunk, 0, NULL);
  return jq_dispatch(rt, hf, v);
}

/* re-run a cloned chain with proper C nesting. frames[0] is the OUTERMOST
   (always the chain's handler frame); frames[n-1] the innermost, which
   receives the resume argument. Consumes every frame. */
static jq_value run_from(jq_rt *rt, jq_block **frames, uint32_t i, uint32_t n, jq_value arg) {
  jq_block *f = frames[i];
  if (is_hf(f)) {
    jq_ks_push(rt, f);
    push_entries_of(rt, f);
    jq_value v = (i + 1 == n) ? arg : run_from(rt, frames, i + 1, n, arg);
    return jq_dispatch(rt, f, v);
  }
  if (i + 1 == n) return jq_tc_drive(rt, jq_frame_code(f)(rt, f, arg));
  /* an un-entered frame joins the stack BEFORE its inner extent runs, so a
     capture passing through finds it at its true depth — BELOW the frames
     the inner extent pushes. (Pushing it lazily at suspension time put it
     ABOVE them, inverting the chain: the DST battery's transformer then
     received the resume argument meant for the innermost frame.) */
  jq_ks_push(rt, f);
  jq_value v = run_from(rt, frames, i + 1, n, arg);
  if (v == JQ_SUSPEND) return JQ_SUSPEND; /* f stays for the outer slice */
  if (rt->ks_len == 0 || rt->ks[rt->ks_len - 1] != f)
    jq_runtime_error("jacquard runtime: resume drive unbalanced the frame stack (internal)");
  jq_ks_pop(rt);
  return jq_tc_drive(rt, jq_frame_code(f)(rt, f, v));
}

static jq_block *clone_frame(jq_block *f) {
  jq_block *c = jq_alloc_block(JQ_FRAME, 0, f->n);
  memcpy(c->payload, f->payload, (size_t)f->n * 8);
  jq_value *slots = jq_frame_slots(c);
  for (uint16_t i = 0; i < jq_frame_n_slots(c); i++) jq_dup(slots[i]);
  return c;
}

/* jq_apply's JQ_RESUME case: [resume] is the applied callee (caller drops
   it after; the captured original is never consumed — multi-shot), [v] the
   single argument, owned. */
jq_value jq_resume(jq_rt *rt, jq_value resume, jq_value v) {
  jq_block *r = jq_block_of(resume);
  uint32_t n = (uint32_t)r->payload[0];
  jq_block **chain = malloc(n * sizeof(jq_block *));
  if (!chain) jq_runtime_error("jacquard runtime: out of memory");
  /* payload stores [hf, ..., innermost]; run_from wants the same order */
  for (uint32_t i = 0; i < n; i++) chain[i] = clone_frame((jq_block *)r->payload[1 + i]);
  jq_value out = run_from(rt, chain, 0, n, v);
  free(chain);
  return out;
}
