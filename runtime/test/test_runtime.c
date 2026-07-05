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
  jq_drop(hv);
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
  if (failures) {
    printf("%d FAILED\n", failures);
    return 1;
  }
  printf("all runtime tests passed\n");
  return 0;
}
