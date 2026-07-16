/* Runtime core tests (task 65 DoD). Built twice by check.sh: once with
 * -fsanitize=address,undefined (correctness), once plain under a small
 * `ulimit -s` (the deep-drop bounded-stack proof). Each case prints
 * "ok <name>"; any failure aborts with a message and nonzero exit. */

#include "../jq_value.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;

#define CHECK(cond, name)                                                      \
  do {                                                                         \
    if (cond) {                                                                \
      printf("ok %s\n", name);                                                 \
    } else {                                                                   \
      printf("FAIL %s (%s:%d)\n", name, __FILE__, __LINE__);                   \
      failures++;                                                              \
    }                                                                          \
  } while (0)

/* 63-bit bounds */
#define JQ_MAX_INT (((int64_t)1 << 62) - 1)
#define JQ_MIN_INT (-JQ_MAX_INT - 1)

static void test_int_tagging(void) {
  CHECK(jq_int_val(jq_int(0)) == 0, "int zero round-trip");
  CHECK(jq_int_val(jq_int(-1)) == -1, "int minus-one round-trip");
  CHECK(jq_int_val(jq_int(JQ_MAX_INT)) == JQ_MAX_INT, "int max round-trip");
  CHECK(jq_int_val(jq_int(JQ_MIN_INT)) == JQ_MIN_INT, "int min round-trip");
  CHECK(jq_is_int(jq_int(42)) && !jq_is_ptr(jq_int(42)), "int tag bits");
}

static void test_int_edges(void) {
  /* goldens pinned from the interpreter (jacquard run, 2026-07-05):
     min_int / -1 = min_int (63-bit wrap); 7 / -2 = -3; 7 mod -2 = 1 */
  CHECK(jq_int_val(jq_int_div(jq_int(JQ_MIN_INT), jq_int(-1))) == JQ_MIN_INT,
        "min_int / -1 wraps to min_int");
  CHECK(jq_int_val(jq_int_div(jq_int(7), jq_int(-2))) == -3,
        "division truncates toward zero");
  CHECK(jq_int_val(jq_int_mod(jq_int(7), jq_int(-2))) == 1,
        "mod takes the dividend's sign");
  CHECK(jq_int_val(jq_int_add(jq_int(JQ_MAX_INT), jq_int(1))) == JQ_MIN_INT,
        "add wraps at 63 bits");
  CHECK(jq_int_val(jq_int_sub(jq_int(JQ_MIN_INT), jq_int(1))) == JQ_MAX_INT,
        "sub wraps at 63 bits");
  CHECK(jq_int_val(jq_int_mul(jq_int(JQ_MIN_INT), jq_int(-1))) == JQ_MIN_INT,
        "mul wraps at 63 bits");
}

static void test_rc_invariants(void) {
  jq_value t = jq_tuple(2, (jq_value[]){ jq_int(1), jq_int(2) });
  CHECK(jq_block_of(t)->rc == 1, "fresh block rc is 1");
  jq_dup(t);
  jq_dup(t);
  CHECK(jq_block_of(t)->rc == 3, "dup increments");
  jq_drop(t);
  jq_drop(t);
  CHECK(jq_block_of(t)->rc == 1, "drop decrements");
  jq_drop(t); /* frees; ASAN owns the proof there is no leak or double free */
  printf("ok final drop frees\n");
}

static void test_shared_child(void) {
  /* one child shared by two tuples: freeing both frees the child once */
  jq_value child = jq_tuple(1, (jq_value[]){ jq_int(7) });
  jq_dup(child);
  jq_value a = jq_tuple(1, (jq_value[]){ child });
  jq_value b = jq_tuple(1, (jq_value[]){ child });
  jq_drop(a);
  CHECK(jq_block_of(child)->rc == 1, "shared child survives first parent");
  jq_drop(b);
  printf("ok shared child freed with second parent\n");
}

static void test_reuse_token(void) {
  jq_value t = jq_tuple(2, (jq_value[]){ jq_int(1), jq_int(2) });
  jq_block *shell = jq_drop_reuse(t);
  CHECK(shell != NULL, "unique block yields its shell");
  /* the caller owns shell + fields; reuse it in place, then free normally */
  shell->payload[0] = jq_int(9);
  shell->rc = 1;
  jq_drop(jq_of_block(shell));

  jq_value u = jq_tuple(1, (jq_value[]){ jq_int(3) });
  jq_dup(u);
  CHECK(jq_drop_reuse(u) == NULL, "shared block yields no shell");
  CHECK(jq_block_of(u)->rc == 1, "drop_reuse decremented the shared block");
  jq_drop(u);
  printf("ok reuse token\n");
}

static void test_deep_list_drop(long n) {
  /* cons chain via 2-tuples; drop the root; the worklist keeps the C stack
     flat — the plain build runs this at 10M under `ulimit -s 1024` */
  jq_value list = jq_int(0); /* nil stand-in */
  for (long i = 0; i < n; i++)
    list = jq_tuple(2, (jq_value[]){ jq_int(i), list });
  jq_drop(list);
  printf("ok deep list drop (%ld nodes)\n", n);
}

static void test_self_slot_closure(void) {
  /* a let-rec closure: env[0] = itself, stored WITHOUT dup (the compile-time
     non-owning discipline); one captured value proves children still drop */
  jq_value captured = jq_tuple(1, (jq_value[]){ jq_int(5) });
  jq_value env[2] = { 0 /* self, patched below */, captured };
  jq_value clo = jq_closure((void *)0xC0DE, 1, 2, env, 0);
  jq_closure_env(clo)[0] = clo; /* self reference, no dup */
  CHECK(jq_block_of(clo)->rc == 1, "self reference does not own");
  CHECK(jq_closure_self_slot(clo) == 0, "self slot index");
  CHECK(jq_closure_arity(clo) == 1, "closure arity");
  jq_drop(clo); /* frees closure AND captured; ASAN proves no leak */
  printf("ok self-slot closure freed by last external drop\n");
}

static void test_statics(void) {
  static jq_block static_tuple = { JQ_RC_STATIC, JQ_TUPLE, 0, 0, {} };
  jq_value s = jq_of_block(&static_tuple);
  for (int i = 0; i < 1000; i++) jq_drop(s);
  for (int i = 0; i < 1000; i++) jq_dup(s);
  CHECK(jq_block_of(s)->rc == JQ_RC_STATIC, "static rc never moves");
}

static void test_mixed_children(void) {
  /* every no-child tag as an owned child of a container: the free walk must
     free them all (the ASAN leak net is the assertion) */
  uint8_t h[32] = { 0 };
  jq_value t = jq_tuple(4, (jq_value[]){
      jq_real(2.5), jq_text((const uint8_t *)"abc", 3), jq_hash(h),
      jq_tuple(1, (jq_value[]){ jq_real(0.5) }) });
  jq_drop(t);
  printf("ok mixed-tag children freed\n");
}

static void test_plain_closure_env(void) {
  /* no self slot: the whole env is owned and must drop */
  jq_value a = jq_tuple(1, (jq_value[]){ jq_int(1) });
  jq_value b = jq_text((const uint8_t *)"env", 3);
  jq_value clo =
      jq_closure((void *)0xC0DE, 2, 2, (jq_value[]){ a, b }, UINT16_MAX);
  CHECK(jq_closure_self_slot(clo) == -1, "no self slot decodes to -1");
  CHECK((jq_block_of(clo)->flags & JQ_FLAG_SELF_SLOT) == 0, "no self flag");
  jq_drop(clo); /* frees a and b too; leak net proves it */
  printf("ok plain closure env freed\n");
}

static void test_reuse_owned_fields(void) {
  /* the token's ownership transfer: the caller takes the old fields, keeps
     one, drops the other, reuses the shell for a new pair */
  jq_value kept = jq_tuple(1, (jq_value[]){ jq_int(1) });
  jq_value dropped = jq_tuple(1, (jq_value[]){ jq_int(2) });
  jq_value pair = jq_tuple(2, (jq_value[]){ kept, dropped });
  jq_block *shell = jq_drop_reuse(pair);
  CHECK(shell != NULL && shell->rc == 1, "shell returned with rc 1");
  jq_drop(shell->payload[1]);         /* the field we do not keep */
  shell->payload[1] = jq_int(9);      /* reuse in place; kept stays owned */
  jq_value reused = jq_of_block(shell);
  CHECK(jq_fields(reused)[0] == kept, "kept field survived the reuse");
  jq_drop(reused); /* frees shell and kept */
  printf("ok reuse transfers field ownership\n");
}

static void test_unit(void) {
  CHECK(jq_is_ptr(JQ_UNIT) && jq_block_of(JQ_UNIT)->tag == JQ_TUPLE &&
            jq_tuple_arity(JQ_UNIT) == 0,
        "unit is the static empty tuple");
  jq_drop(JQ_UNIT);
  CHECK(jq_block_of(JQ_UNIT)->rc == JQ_RC_STATIC, "unit is immortal");
}

static void test_blocks(void) {
  jq_value r = jq_real(1.5);
  CHECK(jq_real_val(r) == 1.5, "real round-trip");
  jq_drop(r);

  const char *msg = "hello jacquard";
  jq_value txt = jq_text((const uint8_t *)msg, strlen(msg));
  CHECK(jq_text_len(txt) == strlen(msg), "text length");
  CHECK(memcmp(jq_text_bytes(txt), msg, strlen(msg)) == 0, "text bytes");
  jq_drop(txt);

  static const jq_con_info some_info = { 1, 0, 1, "some" };
  jq_value inner = jq_tuple(1, (jq_value[]){ jq_int(1) });
  jq_value c = jq_con(&some_info, (jq_value[]){ inner });
  CHECK(jq_con_info_of(c) == &some_info, "con identity is the info pointer");
  CHECK(jq_con_arity(c) == 1, "con arity");
  CHECK(jq_con_fields(c)[0] == inner, "con field");
  jq_drop(c); /* drops inner too */
  printf("ok con block\n");

  uint8_t h[32];
  for (int i = 0; i < 32; i++) h[i] = (uint8_t)i;
  jq_value hv = jq_hash(h);
  CHECK(memcmp(jq_hash_bytes(hv), h, 32) == 0, "hash bytes");
  char *hash_shown = jq_show(hv);
  CHECK(strcmp(hash_shown,
               "#000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f") == 0,
        "hash show uses canonical lowercase hex");
  free(hash_shown);
  static const jq_con_info hash_box_info = { 2, 0, 1, "hash-box" };
  jq_value boxed_hash = jq_con(&hash_box_info, (jq_value[]){ hv });
  char *boxed_shown = jq_show(boxed_hash);
  CHECK(strcmp(boxed_shown,
               "hash-box(#000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f)") == 0,
        "hash show composes inside constructors");
  free(boxed_shown);
  jq_drop(boxed_hash); /* owns and releases hv; ASAN proves the nested path is leak-free */

  const char *fixture = "ET4-native-fixture-secret";
  jq_value secret = jq_secret((const uint8_t *)fixture, strlen(fixture));
  CHECK(jq_is_secret(secret), "secret has a distinct runtime tag");
  CHECK(jq_secret_len(secret) == strlen(fixture) &&
            memcmp(jq_secret_bytes(secret), fixture, strlen(fixture)) == 0,
        "explicit secret accessor preserves bytes");
  char *secret_shown = jq_show(secret);
  CHECK(strcmp(secret_shown, "<secret redacted>") == 0 && strstr(secret_shown, fixture) == NULL,
        "secret show is fixed redaction");
  free(secret_shown);
  jq_value inspected = jq_i_debug_inspect(NULL, (jq_value[]){ secret });
  CHECK(jq_text_len(inspected) == strlen("<secret redacted>") &&
            memcmp(jq_text_bytes(inspected), "<secret redacted>", jq_text_len(inspected)) == 0,
        "native debug.inspect redacts secret bytes");
  jq_drop(inspected);
}

/* --- effects: the handler stack and perform (task 70) --- */

/* Clause code functions use the uniform compiled signature: the callee owns
 * clo and the live arguments; the padding slots are JQ_UNIT (static). */

/* 0-arity clause returning env[0] */
static jq_value hc_env0(JQ_PARAMS) {
  (void)rt; (void)a0; (void)a1; (void)a2; (void)a3; (void)a4; (void)a5;
  (void)a6; (void)a7;
  jq_value r = jq_closure_env(clo)[0];
  jq_dup(r); /* before the clo drop: the env owns its copy until then */
  jq_drop(clo);
  return r;
}

/* 1-arity clause echoing its argument */
static jq_value hc_echo(JQ_PARAMS) {
  (void)rt; (void)a1; (void)a2; (void)a3; (void)a4; (void)a5; (void)a6;
  (void)a7;
  jq_drop(clo);
  return a0;
}

/* 0-arity clause re-performing op env[0], plus 1: outer-continuation
 * semantics say it must reach the handler BELOW its own, never itself */
static jq_value hc_reperform(JQ_PARAMS) {
  (void)a0; (void)a1; (void)a2; (void)a3; (void)a4; (void)a5; (void)a6;
  (void)a7;
  uint32_t op = (uint32_t)jq_int_val(jq_closure_env(clo)[0]);
  jq_drop(clo);
  jq_value inner = jq_perform(rt, op, 0, NULL);
  return jq_int_add(inner, jq_int(1));
}

/* 0-arity clause that pushes a handler for op env[0] (clause value 500) at
 * the truncation point, performs it, pops it, returns the result plus 1 —
 * the structured handle-inside-a-clause shape */
static jq_value hc_nested_push(JQ_PARAMS) {
  (void)a0; (void)a1; (void)a2; (void)a3; (void)a4; (void)a5; (void)a6;
  (void)a7;
  uint32_t op = (uint32_t)jq_int_val(jq_closure_env(clo)[0]);
  jq_drop(clo);
  jq_handler_entry e = { .op_ord = op,
                         .clause = jq_closure((void *)hc_env0, 0, 1,
                                              (jq_value[]){ jq_int(500) },
                                              UINT16_MAX) };
  jq_handle_push(rt, 1, &e);
  jq_value r = jq_perform(rt, op, 0, NULL);
  jq_handle_pop(rt, 1);
  return jq_int_add(r, jq_int(1));
}

static jq_handler_entry entry_const(uint32_t op, int64_t v) {
  return (jq_handler_entry){ .op_ord = op,
                             .clause = jq_closure((void *)hc_env0, 0, 1,
                                                  (jq_value[]){ jq_int(v) },
                                                  UINT16_MAX) };
}

static void test_handler_push_pop(void) {
  /* push takes ownership of the clause closures, pop releases them; the
     captured tuple's free is ASAN's proof */
  jq_rt rt = { 0 };
  jq_value captured = jq_tuple(1, (jq_value[]){ jq_int(9) });
  jq_handler_entry e[2] = {
    entry_const(1, 10),
    { .op_ord = 2,
      .clause = jq_closure((void *)hc_env0, 0, 1, (jq_value[]){ captured },
                           UINT16_MAX) },
  };
  jq_handle_push(&rt, 2, e);
  CHECK(rt.hs_len == 2, "push installs the entries");
  jq_handle_pop(&rt, 2);
  CHECK(rt.hs_len == 0, "pop empties the stack");
  free(rt.hs);
  printf("ok handler push/pop releases clauses\n");
}

static void test_perform_nearest(void) {
  jq_rt rt = { 0 };
  jq_handler_entry outer = entry_const(1, 10);
  jq_handle_push(&rt, 1, &outer);
  jq_handler_entry inner = entry_const(1, 20);
  jq_handle_push(&rt, 1, &inner);
  jq_value r = jq_perform(&rt, 1, 0, NULL);
  CHECK(jq_int_val(r) == 20, "nearest cover wins");
  jq_handle_pop(&rt, 1);
  r = jq_perform(&rt, 1, 0, NULL);
  CHECK(jq_int_val(r) == 10, "pop uncovers the outer handler");
  jq_handle_pop(&rt, 1);
  free(rt.hs);
}

static void test_perform_args_ownership(void) {
  /* the clause owns the live arguments (echo returns ours back); perform
     dups the stack entry's clause per call, so a second perform works */
  jq_rt rt = { 0 };
  jq_handler_entry e = { .op_ord = 4,
                         .clause = jq_closure((void *)hc_echo, 1, 0, NULL,
                                              UINT16_MAX) };
  jq_handle_push(&rt, 1, &e);
  jq_value arg = jq_tuple(1, (jq_value[]){ jq_int(7) });
  jq_value r = jq_perform(&rt, 4, 1, (jq_value[]){ arg });
  CHECK(r == arg, "clause received the owned argument");
  jq_drop(r);
  jq_value arg2 = jq_tuple(1, (jq_value[]){ jq_int(8) });
  r = jq_perform(&rt, 4, 1, (jq_value[]){ arg2 });
  CHECK(r == arg2, "second perform through the same entry");
  jq_drop(r);
  jq_handle_pop(&rt, 1);
  free(rt.hs);
}

static void test_perform_outer_continuation(void) {
  /* a clause body runs against the continuation OUTSIDE its handler: its
     re-perform reaches the handler below, and the hidden slice is restored
     after the clause returns — pinned by performing twice */
  jq_rt rt = { 0 };
  jq_handler_entry below = entry_const(1, 100);
  jq_handle_push(&rt, 1, &below);
  jq_handler_entry above = { .op_ord = 1,
                             .clause = jq_closure((void *)hc_reperform, 0, 1,
                                                  (jq_value[]){ jq_int(1) },
                                                  UINT16_MAX) };
  jq_handle_push(&rt, 1, &above);
  jq_value r = jq_perform(&rt, 1, 0, NULL);
  CHECK(jq_int_val(r) == 101, "clause re-perform reaches the outer handler");
  CHECK(rt.hs_len == 2, "hidden slice restored after the clause");
  r = jq_perform(&rt, 1, 0, NULL);
  CHECK(jq_int_val(r) == 101, "stack intact for a second perform");
  jq_handle_pop(&rt, 2);
  free(rt.hs);
}

static void test_clause_pushes_handler(void) {
  /* a handle inside a clause lands at the truncation point and pops before
     the clause returns */
  jq_rt rt = { 0 };
  jq_handler_entry e = { .op_ord = 1,
                         .clause = jq_closure((void *)hc_nested_push, 0, 1,
                                              (jq_value[]){ jq_int(2) },
                                              UINT16_MAX) };
  jq_handle_push(&rt, 1, &e);
  jq_value r = jq_perform(&rt, 1, 0, NULL);
  CHECK(jq_int_val(r) == 501, "clause-local handle covers its perform");
  CHECK(rt.hs_len == 1, "clause-local handle popped before return");
  jq_handle_pop(&rt, 1);
  free(rt.hs);
}

/* --- effects II: capture, resume, copy-on-resume (task 71) ---
 *
 * These machines are hand-written models of the compiler's frame-style
 * output. Protocol under test (jq_frames.c): save a frame before a
 * suspendable call when rt->cap_depth > 0; on JQ_SUSPEND leave it on
 * rt->ks and propagate; a normal return pops and free()s it (slots are
 * borrowed until the suspension abandons them); re-entry takes the slots
 * back and free()s the frame. */

#define OP_A 40
#define OP_B 41

/* body machine: x = perform(OP_A); x + 1 */
static jq_value m1_reenter(jq_rt *rt, jq_block *f, jq_value v) {
  (void)rt;
  jq_block_free(f);
  return jq_int_add(v, jq_int(1));
}
static jq_value m1_entry(JQ_PARAMS) {
  (void)a0; (void)a1; (void)a2; (void)a3; (void)a4; (void)a5; (void)a6;
  (void)a7;
  jq_drop(clo);
  jq_block *f = NULL;
  if (rt->cap_depth) {
    f = jq_frame_alloc(m1_reenter, 1, 0, 0);
    jq_ks_push(rt, f);
  }
  jq_value r = jq_perform(rt, OP_A, 0, NULL);
  if (r == JQ_SUSPEND) return JQ_SUSPEND;
  if (f) {
    jq_ks_pop(rt);
    jq_block_free(f);
  }
  return jq_int_add(r, jq_int(1));
}

/* clause: resume once with 41 */
static jq_value cl_resume41(JQ_PARAMS) {
  (void)a1; (void)a2; (void)a3; (void)a4; (void)a5; (void)a6; (void)a7;
  jq_drop(clo);
  rt->apply_n = 1;
  return jq_tc_drive(rt, jq_apply(rt, a0, jq_int(41), JQ_UNIT, JQ_UNIT, JQ_UNIT, JQ_UNIT,
                  JQ_UNIT, JQ_UNIT, JQ_UNIT));
}

/* clause: resume twice (1 then 2), tuple the branch values */
static jq_value cl_twice(JQ_PARAMS) {
  (void)a1; (void)a2; (void)a3; (void)a4; (void)a5; (void)a6; (void)a7;
  jq_drop(clo);
  jq_dup(a0);
  rt->apply_n = 1;
  jq_value r1 = jq_tc_drive(rt, jq_apply(rt, a0, jq_int(1), JQ_UNIT, JQ_UNIT, JQ_UNIT,
                         JQ_UNIT, JQ_UNIT, JQ_UNIT, JQ_UNIT));
  rt->apply_n = 1;
  jq_value r2 = jq_tc_drive(rt, jq_apply(rt, a0, jq_int(2), JQ_UNIT, JQ_UNIT, JQ_UNIT,
                         JQ_UNIT, JQ_UNIT, JQ_UNIT, JQ_UNIT));
  return jq_tuple(2, (jq_value[]){ r1, r2 });
}

/* clause: never resume — drop the resumption, return 999 */
static jq_value cl_abort999(JQ_PARAMS) {
  (void)rt; (void)a1; (void)a2; (void)a3; (void)a4; (void)a5; (void)a6;
  (void)a7;
  jq_drop(clo);
  jq_drop(a0);
  return jq_int(999);
}

/* clause: escape — return the resumption itself */
static jq_value cl_escape(JQ_PARAMS) {
  (void)rt; (void)a1; (void)a2; (void)a3; (void)a4; (void)a5; (void)a6;
  (void)a7;
  jq_drop(clo);
  return a0;
}

/* clause for OP_A that performs OP_B (must escape OUTWARD, past this very
   handler even though it also covers OP_B) and returns the result */
static jq_value cl_perform_b(JQ_PARAMS) {
  (void)a1; (void)a2; (void)a3; (void)a4; (void)a5; (void)a6; (void)a7;
  jq_drop(clo);
  jq_drop(a0); /* never resumes */
  return jq_perform(rt, OP_B, 0, NULL);
}

/* ret clauses */
static jq_value rc_id(JQ_PARAMS) {
  (void)rt; (void)a1; (void)a2; (void)a3; (void)a4; (void)a5; (void)a6;
  (void)a7;
  jq_drop(clo);
  return a0;
}
static jq_value rc_double(JQ_PARAMS) {
  (void)rt; (void)a1; (void)a2; (void)a3; (void)a4; (void)a5; (void)a6;
  (void)a7;
  jq_drop(clo);
  return jq_int_mul(a0, jq_int(2));
}
static jq_value rc_add1000(JQ_PARAMS) {
  (void)rt; (void)a1; (void)a2; (void)a3; (void)a4; (void)a5; (void)a6;
  (void)a7;
  jq_drop(clo);
  return jq_int_add(a0, jq_int(1000));
}

static jq_value clo0(jq_fn code) { return jq_closure((void *)code, 0, 0, NULL, UINT16_MAX); }
static jq_value clo1(jq_fn code) { return jq_closure((void *)code, 1, 0, NULL, UINT16_MAX); }

static void test_capture_single_resume(void) {
  jq_rt rt = { 0 };
  jq_handler_entry e = { OP_A, clo1(cl_resume41), JQ_CLAUSE_CAPTURING, true, NULL };
  jq_value out = jq_handle2(&rt, 1, &e, clo0(m1_entry), clo1(rc_id));
  CHECK(jq_int_val(out) == 42, "capture + resume once yields 42");
  CHECK(rt.ks_len == 0 && rt.hs_len == 0 && rt.cap_depth == 0,
        "stacks balanced after handle2");
  free(rt.hs);
  free(rt.ks);
}

static void test_once_instances_are_independent(void) {
  /* The use bit belongs to the captured JQ_RESUME block: a later perform
     allocates a fresh block and therefore has its own one-resume budget. */
  jq_rt rt = { 0 };
  jq_handler_entry left = { OP_A, clo1(cl_resume41), JQ_CLAUSE_CAPTURING, true, NULL };
  jq_value first = jq_handle2(&rt, 1, &left, clo0(m1_entry), clo1(rc_id));
  CHECK(jq_int_val(first) == 42, "first once instance resumes");
  jq_handler_entry right = { OP_A, clo1(cl_resume41), JQ_CLAUSE_CAPTURING, true, NULL };
  jq_value second = jq_handle2(&rt, 1, &right, clo0(m1_entry), clo1(rc_id));
  CHECK(jq_int_val(second) == 42, "fresh once instance has a fresh budget");
  CHECK(rt.ks_len == 0 && rt.hs_len == 0 && rt.cap_depth == 0,
        "stacks balanced after separate once captures");
  free(rt.hs);
  free(rt.ks);
}

static void test_multishot_two_resumes(void) {
  /* body adds 1; the clause resumes with 1 then 2: (2, 3). Copy-on-resume
     makes the second resume independent of the first. */
  jq_rt rt = { 0 };
  jq_handler_entry e = { OP_A, clo1(cl_twice), JQ_CLAUSE_CAPTURING, false, NULL };
  jq_value out = jq_handle2(&rt, 1, &e, clo0(m1_entry), clo1(rc_id));
  CHECK(jq_is_ptr(out) && jq_block_of(out)->tag == JQ_TUPLE, "multi-shot returns the tuple");
  CHECK(jq_int_val(jq_fields(out)[0]) == 2 && jq_int_val(jq_fields(out)[1]) == 3,
        "multi-shot branches are independent (2, 3)");
  jq_drop(out);
  CHECK(rt.ks_len == 0 && rt.hs_len == 0 && rt.cap_depth == 0,
        "stacks balanced after multi-shot");
  free(rt.hs);
  free(rt.ks);
}

/* body machine with a live heap local across the perform: t = (7);
   x = perform(OP_A); t.0 + x — the abort test proves the captured chain
   frees t (ASAN's leak net is the assertion) */
static jq_value m2_reenter(jq_rt *rt, jq_block *f, jq_value v) {
  (void)rt;
  jq_value t = jq_frame_slots(f)[0]; /* take ownership back */
  jq_block_free(f);
  jq_value x0 = jq_fields(t)[0];
  jq_value r = jq_int_add(x0, v);
  jq_drop(t);
  return r;
}
static jq_value m2_entry(JQ_PARAMS) {
  (void)a0; (void)a1; (void)a2; (void)a3; (void)a4; (void)a5; (void)a6;
  (void)a7;
  jq_drop(clo);
  jq_value t = jq_tuple(1, (jq_value[]){ jq_int(7) });
  jq_block *f = NULL;
  if (rt->cap_depth) {
    f = jq_frame_alloc(m2_reenter, 1, 0, 1);
    jq_frame_slots(f)[0] = t; /* borrowed mirror until a suspension */
    jq_ks_push(rt, f);
  }
  jq_value r = jq_perform(rt, OP_A, 0, NULL);
  if (r == JQ_SUSPEND) return JQ_SUSPEND;
  if (f) {
    jq_ks_pop(rt);
    jq_block_free(f);
  }
  jq_value x0 = jq_fields(t)[0];
  jq_value out = jq_int_add(x0, r);
  jq_drop(t);
  return out;
}

static void test_abort_drops_chain(void) {
  /* the clause never resumes: dropping the resumption must free the
     captured frame AND its heap local; ret must NOT run (would add 1000) */
  jq_rt rt = { 0 };
  jq_handler_entry e = { OP_A, clo1(cl_abort999), JQ_CLAUSE_CAPTURING, true, NULL };
  jq_value out = jq_handle2(&rt, 1, &e, clo0(m2_entry), clo1(rc_add1000));
  CHECK(jq_int_val(out) == 999, "abort value bypasses the ret clause");
  CHECK(rt.ks_len == 0 && rt.hs_len == 0 && rt.cap_depth == 0,
        "stacks balanced after abort");
  free(rt.hs);
  free(rt.ks);
}

static void test_escaped_resume_ret_per_resumption(void) {
  /* the clause returns the resumption; applying it twice outside the
     handler's textual scope runs body-remainder AND ret per application */
  jq_rt rt = { 0 };
  jq_handler_entry e = { OP_A, clo1(cl_escape), JQ_CLAUSE_CAPTURING, false, NULL };
  jq_value res = jq_handle2(&rt, 1, &e, clo0(m1_entry), clo1(rc_double));
  CHECK(jq_is_ptr(res) && jq_block_of(res)->tag == JQ_RESUME,
        "escaped resumption is the handle's value");
  jq_dup(res);
  rt.apply_n = 1;
  jq_value r1 = jq_tc_drive(&rt, jq_apply(&rt, res, jq_int(10), JQ_UNIT, JQ_UNIT, JQ_UNIT,
                         JQ_UNIT, JQ_UNIT, JQ_UNIT, JQ_UNIT));
  CHECK(jq_int_val(r1) == 22, "first outside resume: (10+1)*2");
  rt.apply_n = 1;
  jq_value r2 = jq_tc_drive(&rt, jq_apply(&rt, res, jq_int(20), JQ_UNIT, JQ_UNIT, JQ_UNIT,
                         JQ_UNIT, JQ_UNIT, JQ_UNIT, JQ_UNIT));
  CHECK(jq_int_val(r2) == 42, "second outside resume: (20+1)*2");
  CHECK(rt.ks_len == 0 && rt.hs_len == 0 && rt.cap_depth == 0,
        "stacks balanced after escaped resumes");
  free(rt.hs);
  free(rt.ks);
}

static jq_value m3_entry(JQ_PARAMS);

static void test_clause_perform_escapes_outward(void) {
  /* inner handler covers OP_A and OP_B; its OP_A clause performs OP_B,
     which must reach the OUTER handler (the clause runs against the outer
     continuation), not the inner one — the inner OP_B clause would return
     999 and the inner ret would add 1000, so 42 proves both were skipped */
  jq_rt rt = { 0 };
  jq_handler_entry outer = { OP_B, clo1(cl_resume41), JQ_CLAUSE_CAPTURING, false, NULL };
  jq_value out = jq_handle2(&rt, 1, &outer, clo0(m3_entry), clo1(rc_id));
  /* inner OP_A clause performs OP_B; outer clause resumes it with 41; the
     inner clause returns that 41 as the inner handle's value; inner ret
     does not run (abort path); m3 adds 1 => 42 */
  CHECK(jq_int_val(out) == 42, "clause-body perform escaped outward");
  CHECK(rt.ks_len == 0 && rt.hs_len == 0 && rt.cap_depth == 0,
        "stacks balanced after outward escape");
  free(rt.hs);
  free(rt.ks);
}

/* the outer body: v = handle2(inner) ; v + 1 — with suspend protocol */
static jq_value m3_reenter(jq_rt *rt, jq_block *f, jq_value v) {
  (void)rt;
  jq_block_free(f);
  return jq_int_add(v, jq_int(1));
}
static jq_value m3_entry(JQ_PARAMS) {
  (void)a0; (void)a1; (void)a2; (void)a3; (void)a4; (void)a5; (void)a6;
  (void)a7;
  jq_drop(clo);
  jq_block *f = NULL;
  if (rt->cap_depth) {
    f = jq_frame_alloc(m3_reenter, 1, 0, 0);
    jq_ks_push(rt, f);
  }
  jq_handler_entry inner[2] = {
    { OP_A, clo1(cl_perform_b), JQ_CLAUSE_CAPTURING, false, NULL },
    { OP_B, clo1(cl_abort999), JQ_CLAUSE_CAPTURING, false, NULL },
  };
  jq_value r = jq_handle2(rt, 2, inner, clo0(m1_entry), clo1(rc_add1000));
  if (r == JQ_SUSPEND) return JQ_SUSPEND;
  if (f) {
    jq_ks_pop(rt);
    jq_block_free(f);
  }
  return jq_int_add(r, jq_int(1));
}

/* deep handler: body performs OP_A twice (x = perform; y = perform; x+y);
   the clause resumes each with 10; the second perform must be re-covered
   by the resumed chain's handler frame (deep semantics) => 20 */
static jq_value m4_reenter(jq_rt *rt, jq_block *f, jq_value v) {
  uint64_t ix = jq_frame_ix(f);
  if (ix == 1) {
    jq_block_free(f);
    jq_value x = v;
    jq_block *f2 = NULL;
    if (rt->cap_depth) {
      f2 = jq_frame_alloc(m4_reenter, 2, 0, 1);
      jq_frame_slots(f2)[0] = x;
      jq_ks_push(rt, f2);
    }
    jq_value r = jq_perform(rt, OP_A, 0, NULL);
    if (r == JQ_SUSPEND) return JQ_SUSPEND;
    if (f2) {
      jq_ks_pop(rt);
      jq_block_free(f2);
    }
    return jq_int_add(x, r);
  }
  /* ix 2: x lives in the slot */
  jq_value x = jq_frame_slots(f)[0];
  jq_block_free(f);
  return jq_int_add(x, v);
}
static jq_value m4_entry(JQ_PARAMS) {
  (void)a0; (void)a1; (void)a2; (void)a3; (void)a4; (void)a5; (void)a6;
  (void)a7;
  jq_drop(clo);
  jq_block *f = NULL;
  if (rt->cap_depth) {
    f = jq_frame_alloc(m4_reenter, 1, 0, 0);
    jq_ks_push(rt, f);
  }
  jq_value r = jq_perform(rt, OP_A, 0, NULL);
  if (r == JQ_SUSPEND) return JQ_SUSPEND;
  if (f) {
    jq_ks_pop(rt);
    jq_block_free(f);
  }
  /* never reached uncaptured in this test */
  return m4_reenter(rt, jq_frame_alloc(m4_reenter, 1, 0, 0), r);
}

static jq_value cl_resume10(JQ_PARAMS) {
  (void)a1; (void)a2; (void)a3; (void)a4; (void)a5; (void)a6; (void)a7;
  jq_drop(clo);
  rt->apply_n = 1;
  return jq_tc_drive(rt, jq_apply(rt, a0, jq_int(10), JQ_UNIT, JQ_UNIT, JQ_UNIT, JQ_UNIT,
                  JQ_UNIT, JQ_UNIT, JQ_UNIT));
}

static void test_deep_handler_recovers_inner_performs(void) {
  jq_rt rt = { 0 };
  jq_handler_entry e = { OP_A, clo1(cl_resume10), JQ_CLAUSE_CAPTURING, false, NULL };
  jq_value out = jq_handle2(&rt, 1, &e, clo0(m4_entry), clo1(rc_id));
  CHECK(jq_int_val(out) == 20, "deep handler covers the resumed extent");
  CHECK(rt.ks_len == 0 && rt.hs_len == 0 && rt.cap_depth == 0,
        "stacks balanced after deep re-cover");
  free(rt.hs);
  free(rt.ks);
}

/* chain-order regression (task 72's DST divergence): when a resumed chain
 * suspends again for an OUTER handler, an un-entered middle frame must sit
 * BELOW the inner extent's new frames in the outer slice — the re-entry
 * order is value-distinguishable here (inner scales, outer doubles). */

/* inner machine: pa = perform(OP_A); pb = perform(OP_B); pa*1000 + pb */
static jq_value m5_in_reenter(jq_rt *rt, jq_block *f, jq_value v) {
  uint64_t ix = jq_frame_ix(f);
  if (ix == 1) {
    jq_block_free(f);
    jq_value pa = v;
    jq_block *f2 = NULL;
    if (rt->cap_depth) {
      f2 = jq_frame_alloc(m5_in_reenter, 2, 0, 1);
      jq_frame_slots(f2)[0] = pa;
      jq_ks_push(rt, f2);
    }
    jq_value r = jq_perform(rt, OP_B, 0, NULL);
    if (r == JQ_SUSPEND) return JQ_SUSPEND;
    if (f2) {
      jq_ks_pop(rt);
      jq_block_free(f2);
    }
    return jq_int_add(jq_int_mul(pa, jq_int(1000)), r);
  }
  jq_value pa = jq_frame_slots(f)[0];
  jq_block_free(f);
  return jq_int_add(jq_int_mul(pa, jq_int(1000)), v);
}
static jq_value m5_in_entry(JQ_PARAMS) {
  (void)a0; (void)a1; (void)a2; (void)a3; (void)a4; (void)a5; (void)a6;
  (void)a7;
  jq_drop(clo);
  jq_block *f = NULL;
  if (rt->cap_depth) {
    f = jq_frame_alloc(m5_in_reenter, 1, 0, 0);
    jq_ks_push(rt, f);
  }
  jq_value r = jq_perform(rt, OP_A, 0, NULL);
  if (r == JQ_SUSPEND) return JQ_SUSPEND;
  if (f) {
    jq_ks_pop(rt);
    jq_block_free(f);
  }
  return m5_in_reenter(rt, jq_frame_alloc(m5_in_reenter, 1, 0, 0), r);
}

/* outer machine: v = call inner (suspendable); v * 2 */
static jq_value m5_out_reenter(jq_rt *rt, jq_block *f, jq_value v) {
  (void)rt;
  jq_block_free(f);
  return jq_int_mul(v, jq_int(2));
}
static jq_value m5_out_entry(JQ_PARAMS) {
  (void)a0; (void)a1; (void)a2; (void)a3; (void)a4; (void)a5; (void)a6;
  (void)a7;
  jq_drop(clo);
  jq_block *f = NULL;
  if (rt->cap_depth) {
    f = jq_frame_alloc(m5_out_reenter, 1, 0, 0);
    jq_ks_push(rt, f);
  }
  rt->apply_n = 0;
  jq_value r = jq_tc_drive(rt, jq_apply(rt, clo0(m5_in_entry), JQ_UNIT, JQ_UNIT, JQ_UNIT,
                        JQ_UNIT, JQ_UNIT, JQ_UNIT, JQ_UNIT, JQ_UNIT));
  if (r == JQ_SUSPEND) return JQ_SUSPEND;
  if (f) {
    jq_ks_pop(rt);
    jq_block_free(f);
  }
  return jq_int_mul(r, jq_int(2));
}

/* the outer-B thunk: r = handle2(A: escape) over m5_out; apply r(7) */
static jq_value m5_thunk_reenter(jq_rt *rt, jq_block *f, jq_value v) {
  uint64_t ix = jq_frame_ix(f);
  if (ix == 1) {
    jq_block_free(f);
    /* v = the escaped resumption; apply it to 7 (suspendable) */
    jq_block *f2 = NULL;
    if (rt->cap_depth) {
      f2 = jq_frame_alloc(m5_thunk_reenter, 2, 0, 0);
      jq_ks_push(rt, f2);
    }
    rt->apply_n = 1;
    jq_value r = jq_tc_drive(rt, jq_apply(rt, v, jq_int(7), JQ_UNIT, JQ_UNIT, JQ_UNIT,
                          JQ_UNIT, JQ_UNIT, JQ_UNIT, JQ_UNIT));
    if (r == JQ_SUSPEND) return JQ_SUSPEND;
    if (f2) {
      jq_ks_pop(rt);
      jq_block_free(f2);
    }
    return r;
  }
  jq_block_free(f);
  return v; /* ix 2: the applied resumption's value is the thunk's value */
}
static jq_value m5_thunk_entry(JQ_PARAMS) {
  (void)a0; (void)a1; (void)a2; (void)a3; (void)a4; (void)a5; (void)a6;
  (void)a7;
  jq_drop(clo);
  jq_block *f = NULL;
  if (rt->cap_depth) {
    f = jq_frame_alloc(m5_thunk_reenter, 1, 0, 0);
    jq_ks_push(rt, f);
  }
  jq_handler_entry inner = { OP_A, clo1(cl_escape), JQ_CLAUSE_CAPTURING, false, NULL };
  jq_value r = jq_handle2(rt, 1, &inner, clo0(m5_out_entry), clo1(rc_id));
  if (r == JQ_SUSPEND) return JQ_SUSPEND;
  if (f) {
    jq_ks_pop(rt);
    jq_block_free(f);
  }
  return m5_thunk_reenter(rt, jq_frame_alloc(m5_thunk_reenter, 1, 0, 0), r);
}

static jq_value cl_resume5(JQ_PARAMS) {
  (void)a1; (void)a2; (void)a3; (void)a4; (void)a5; (void)a6; (void)a7;
  jq_drop(clo);
  rt->apply_n = 1;
  return jq_tc_drive(rt, jq_apply(rt, a0, jq_int(5), JQ_UNIT, JQ_UNIT, JQ_UNIT, JQ_UNIT,
                  JQ_UNIT, JQ_UNIT, JQ_UNIT));
}

static void test_chain_order_across_nested_capture(void) {
  /* escaped A-resumption applied inside a B-handle; the resumed extent
     performs B, so the un-entered outer frame joins B's slice below the
     inner frame. Correct order: inner gets 5 (7*1000+5=7005), outer
     doubles (14010), A's ret passes it through. Inverted order gave the
     outer frame the 5. */
  jq_rt rt = { 0 };
  jq_handler_entry outer = { OP_B, clo1(cl_resume5), JQ_CLAUSE_CAPTURING, false, NULL };
  jq_value out = jq_handle2(&rt, 1, &outer, clo0(m5_thunk_entry), clo1(rc_id));
  CHECK(jq_int_val(out) == 14010, "un-entered frame keeps its chain depth");
  CHECK(rt.ks_len == 0 && rt.hs_len == 0 && rt.cap_depth == 0,
        "stacks balanced after nested re-capture");
  free(rt.hs);
  free(rt.ks);
}

static int fake_grant_calls = 0;
static jq_value fake_grant(jq_rt *rt, const jq_value *args) {
  (void)rt;
  (void)args;
  fake_grant_calls++;
  return jq_int(777);
}

static void test_grant_fallback(void) {
  /* an uncovered op falls to the grant table by ordinal; a handler for a
     DIFFERENT op does not intercept, a handler covering the op shadows */
  jq_rt rt = { 0 };
  jq_value (*grants[4])(jq_rt *, const jq_value *) = { 0 };
  grants[3] = fake_grant;
  rt.grants = grants;
  rt.n_ops = 4;
  jq_handler_entry other = entry_const(1, 10);
  jq_handle_push(&rt, 1, &other);
  jq_value r = jq_perform(&rt, 3, 0, NULL);
  CHECK(jq_int_val(r) == 777 && fake_grant_calls == 1,
        "uncovered op falls to its grant");
  jq_handler_entry cover = entry_const(3, 30);
  jq_handle_push(&rt, 1, &cover);
  r = jq_perform(&rt, 3, 0, NULL);
  CHECK(jq_int_val(r) == 30 && fake_grant_calls == 1,
        "a covering handler shadows the grant");
  jq_handle_pop(&rt, 2);
  free(rt.hs);
}

static void test_inert_task_handles(void) {
  int run_a = 0, run_b = 0;
  uint32_t root[] = { 0 };
  uint32_t nested[] = { 0, 2 };
  jq_value task = JQ_UNIT;
  CHECK(jq_task_create(&run_a, nested, 2, 3, &task) == JQ_TASK_VALID,
        "task deterministic ID constructs");
  CHECK(jq_block_of(task)->tag == JQ_TASK, "task has a distinct opaque native tag");
  CHECK(jq_task_validate(task, &run_a, nested, 2) == JQ_TASK_VALID,
        "task validates in its owning run and scope");
  CHECK(jq_task_validate(task, &run_b, nested, 2) == JQ_TASK_FOREIGN_RUN,
        "task rejects cross-run reuse");
  CHECK(jq_task_validate(task, &run_a, root, 1) == JQ_TASK_FOREIGN_SCOPE,
        "task rejects cross-scope reuse");
  CHECK(jq_task_validate(jq_int(7), &run_a, root, 1) == JQ_TASK_MALFORMED,
        "malformed task diagnoses without a crash");
  char *shown = jq_show(task);
  CHECK(strcmp(shown, "<task>") == 0, "native task diagnostics remain opaque");
  free(shown);
  jq_drop(task);
  CHECK(jq_task_create(&run_a, (uint32_t[]){ 1 }, 1, 0, &task) == JQ_TASK_MALFORMED,
        "invalid task path diagnoses without allocation");
  uint16_t max_scope_len = JQ_TASK_MAX_SCOPE_LEN;
  uint32_t *deep = calloc(max_scope_len + 1, sizeof(*deep));
  if (!deep) abort();
  for (uint32_t i = 1; i <= max_scope_len; i++) deep[i] = JQ_TASK_MAX_COMPONENT;
  CHECK(jq_task_create(&run_a, deep, max_scope_len, JQ_TASK_MAX_COMPONENT, &task) == JQ_TASK_VALID,
        "native uint32/uint16 Task ID boundary constructs");
  CHECK(jq_task_validate(task, &run_a, deep, max_scope_len) == JQ_TASK_VALID,
        "native maximum Task ID validates");
  jq_block_of(task)->payload[2 + max_scope_len] =
    (uint64_t)JQ_TASK_MAX_COMPONENT + UINT64_C(1);
  CHECK(jq_task_validate(task, &run_a, deep, max_scope_len) == JQ_TASK_MALFORMED,
        "native Task spawn index one past uint32 diagnoses");
  jq_drop(task);
  CHECK(jq_task_create(&run_a, deep, (uint16_t)(max_scope_len + 1), 0, &task) ==
            JQ_TASK_MALFORMED,
        "native Task block depth overflow diagnoses");
  free(deep);
}

int main(int argc, char **argv) {
  /* fatal-path modes: check.sh asserts the message and exit code 2 */
  if (argc > 1 && strcmp(argv[1], "div0") == 0) {
    jq_int_div_checked(jq_int(1), jq_int(0));
    return 0; /* unreachable */
  }
  if (argc > 1 && strcmp(argv[1], "mod0") == 0) {
    jq_int_mod_checked(jq_int(1), jq_int(0));
    return 0;
  }
  if (argc > 1 && strcmp(argv[1], "arity-overflow") == 0) {
    static const jq_con_info huge = { 0, 0, 65535, "huge" };
    jq_value fields[1] = { jq_int(0) }; /* never copied: the guard fires first */
    jq_con(&huge, fields);
    return 0;
  }
  if (argc > 1 && strcmp(argv[1], "secret-code-of-text") == 0) {
    const char *fixture = "ET4-MUST-NOT-APPEAR";
    jq_value secret = jq_secret((const uint8_t *)fixture, strlen(fixture));
    jq_i_code_of_text(NULL, (jq_value[]){ secret });
    return 0; /* unreachable */
  }
  if (argc > 1 && strcmp(argv[1], "match-fail") == 0) {
    /* surface-unreachable (the checker refuses inexhaustive matches with
       E0813) but the defensive rendering must stay interpreter-exact */
    jq_rt rt = { 0 };
    jq_match_fail(&rt, jq_int(5));
    return 0; /* unreachable */
  }
  if (argc > 1 && strcmp(argv[1], "unhandled-op") == 0) {
    /* no handler, no grant: the interpreter's exact rendering, exit 3 */
    static const jq_op_info print_info = { NULL, "console", "print", 0 };
    static const jq_op_info *meta[1] = { &print_info };
    jq_rt rt = { 0 };
    rt.op_meta = meta;
    rt.n_ops = 1;
    jq_perform(&rt, 0, 0, NULL);
    return 0; /* unreachable */
  }
  if (argc > 1 && strcmp(argv[1], "once-resume-twice") == 0) {
    jq_rt rt = { 0 };
    jq_handler_entry e = { OP_A, clo1(cl_twice), JQ_CLAUSE_CAPTURING, true, NULL };
    (void)jq_handle2(&rt, 1, &e, clo0(m1_entry), clo1(rc_id));
    return 0; /* unreachable */
  }
  long deep_n = argc > 1 ? atol(argv[1]) : 1000000;
  test_int_tagging();
  test_int_edges();
  test_rc_invariants();
  test_shared_child();
  test_reuse_token();
  test_deep_list_drop(deep_n);
  test_self_slot_closure();
  test_plain_closure_env();
  test_mixed_children();
  test_reuse_owned_fields();
  test_unit();
  test_statics();
  test_blocks();
  test_handler_push_pop();
  test_perform_nearest();
  test_perform_args_ownership();
  test_perform_outer_continuation();
  test_clause_pushes_handler();
  test_grant_fallback();
  test_inert_task_handles();
  test_capture_single_resume();
  test_once_instances_are_independent();
  test_multishot_two_resumes();
  test_abort_drops_chain();
  test_escaped_resume_ret_per_resumption();
  test_clause_perform_escapes_outward();
  test_deep_handler_recovers_inner_performs();
  test_chain_order_across_nested_capture();
  if (failures) {
    printf("%d FAILED\n", failures);
    return 1;
  }
  printf("all runtime tests passed\n");
  return 0;
}
