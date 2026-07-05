/* Block allocation (task 65). Plain malloc/free in v1 — profile before
 * building anything cleverer (docs/native-plan.md, task 75). */

#include "jq_value.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void oom(void) {
  fputs("jacquard runtime: out of memory\n", stderr);
  exit(2);
}

/* the header's n is uint16: arity limits are a representation invariant, and
   exceeding one must abort cleanly, never corrupt (silent memcpy past the
   block was the failure mode this guards) */
static void arity_guard(uint64_t needed, const char *what) {
  if (needed > UINT16_MAX) {
    fprintf(stderr, "jacquard runtime: %s exceeds the 65535 limit\n", what);
    exit(2);
  }
}

jq_block jq_unit_block = { JQ_RC_STATIC, JQ_TUPLE, 0, 0, {} };

jq_block *jq_alloc_block(uint8_t tag, uint8_t flags, uint16_t n) {
  jq_block *b = malloc(sizeof(jq_block) + (size_t)n * 8);
  if (!b) oom();
  b->rc = 1;
  b->tag = tag;
  b->flags = flags;
  b->n = n;
  return b;
}

/* TEXT needs byte-granular payload after the length word. */
static jq_block *alloc_text_block(uint64_t len) {
  if (len > ((uint64_t)1 << 48)) oom(); /* absurd length: refuse before the size math */
  /* payload: 1 length word + len bytes, rounded up to whole words */
  uint64_t words = 1 + (len + 7) / 8;
  if (words > UINT16_MAX) {
    /* n caps at 65535 words; longer texts keep n = 0 and rely on the length
       word (the free walk never looks at TEXT payloads, so n is only a
       convenience) */
    words = 0;
  }
  jq_block *b = malloc(sizeof(jq_block) + 8 + (size_t)((len + 7) / 8) * 8);
  if (!b) oom();
  b->rc = 1;
  b->tag = JQ_TEXT;
  b->flags = 0;
  b->n = (uint16_t)words;
  return b;
}

jq_value jq_tuple(uint16_t n, const jq_value *items) {
  jq_block *b = jq_alloc_block(JQ_TUPLE, 0, n);
  memcpy(b->payload, items, (size_t)n * 8);
  return jq_of_block(b);
}

jq_value jq_con(const jq_con_info *info, const jq_value *fields) {
  arity_guard((uint64_t)info->arity + 1, "constructor arity");
  jq_block *b = jq_alloc_block(JQ_CON, 0, (uint16_t)(info->arity + 1));
  b->payload[0] = (uint64_t)info;
  memcpy(&b->payload[1], fields, (size_t)info->arity * 8);
  return jq_of_block(b);
}

jq_value jq_real(double d) {
  jq_block *b = jq_alloc_block(JQ_REAL, 0, 1);
  union { double d; uint64_t u; } c = { .d = d };
  b->payload[0] = c.u;
  return jq_of_block(b);
}

jq_value jq_text(const uint8_t *bytes, uint64_t len) {
  jq_block *b = alloc_text_block(len);
  b->payload[0] = len;
  memcpy(&b->payload[1], bytes, len);
  return jq_of_block(b);
}

jq_value jq_hash(const uint8_t bytes[32]) {
  jq_block *b = jq_alloc_block(JQ_HASH, 0, 4);
  memcpy(b->payload, bytes, 32);
  return jq_of_block(b);
}

jq_value jq_closure(void *code, uint16_t arity, uint16_t env_n,
                    const jq_value *env, uint16_t self_slot) {
  arity_guard((uint64_t)env_n + 2, "closure environment");
  jq_block *b = jq_alloc_block(
      JQ_CLOSURE, self_slot == UINT16_MAX ? 0 : JQ_FLAG_SELF_SLOT,
      (uint16_t)(env_n + 2));
  b->payload[0] = (uint64_t)code;
  b->payload[1] =
      (uint64_t)arity |
      ((uint64_t)(self_slot == UINT16_MAX ? 0 : (uint32_t)self_slot + 1) << 16);
  memcpy(&b->payload[2], env, (size_t)env_n * 8);
  return jq_of_block(b);
}
