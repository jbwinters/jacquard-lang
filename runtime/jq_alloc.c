/* Block allocation (task 65; the small-block pool is task 80). Blocks of
 * 1-4 payload words — cons cells, small tuples, closures, reals — come
 * from per-size freelists carved out of grow-only slabs: the profile
 * showed the collections core spending its life in malloc/free (3.7M
 * jq_con per 200k sort), and a jemalloc preload only bought ~9%. Bigger
 * blocks stay on libc malloc. The pool is compiled OUT under ASAN so the
 * sanitizer gates keep their use-after-free power; slabs hang off a
 * global list, so LeakSanitizer sees pool memory as reachable, and the
 * program thread is the only allocator (jq_run_main runs one thread). */

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

#if defined(__SANITIZE_ADDRESS__)
#define JQ_POOL_OFF 1
#elif defined(__has_feature)
#if __has_feature(address_sanitizer)
#define JQ_POOL_OFF 1
#endif
#endif

#ifndef JQ_POOL_OFF

#define JQ_POOL_MAX_WORDS 4
#define JQ_SLAB_BYTES 65536

/* freelists by payload word count; a dead block's payload[0] is the link */
static jq_block *jq_freelist[JQ_POOL_MAX_WORDS + 1];
static uint8_t *jq_slab_cur;
static uint8_t *jq_slab_end;
static void **jq_slabs; /* chain head: keeps every slab reachable for LSan */

static jq_block *pool_alloc(uint16_t n) {
  jq_block *b = jq_freelist[n];
  if (b) {
    jq_freelist[n] = (jq_block *)b->payload[0];
    return b;
  }
  size_t sz = sizeof(jq_block) + (size_t)n * 8;
  if ((size_t)(jq_slab_end - jq_slab_cur) < sz) {
    void **slab = malloc(JQ_SLAB_BYTES);
    if (!slab) oom();
    slab[0] = jq_slabs; /* word 0 links the slab chain */
    jq_slabs = slab;
    jq_slab_cur = (uint8_t *)slab + sizeof(void *);
    jq_slab_end = (uint8_t *)slab + JQ_SLAB_BYTES;
  }
  b = (jq_block *)jq_slab_cur;
  jq_slab_cur += sz;
  return b;
}

#endif /* !JQ_POOL_OFF */

jq_block *jq_alloc_block(uint8_t tag, uint8_t flags, uint16_t n) {
#ifndef JQ_POOL_OFF
  if (n >= 1 && n <= JQ_POOL_MAX_WORDS) {
    jq_block *b = pool_alloc(n);
    b->rc = 1;
    b->tag = tag;
    b->flags = flags | JQ_FLAG_POOLED;
    b->n = n;
    return b;
  }
#endif
  jq_block *b = malloc(sizeof(jq_block) + (size_t)n * 8);
  if (!b) oom();
  b->rc = 1;
  b->tag = tag;
  b->flags = flags;
  b->n = n;
  return b;
}

void jq_block_free(jq_block *b) {
#ifndef JQ_POOL_OFF
  if (b->flags & JQ_FLAG_POOLED) {
    b->payload[0] = (uint64_t)jq_freelist[b->n];
    jq_freelist[b->n] = b;
    return;
  }
#endif
  free(b);
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

jq_value jq_tuple(uint32_t n, const jq_value *items) {
  arity_guard(n, "tuple arity");
  jq_block *b = jq_alloc_block(JQ_TUPLE, 0, (uint16_t)n);
  if (n) memcpy(b->payload, items, (size_t)n * 8);
  return jq_of_block(b);
}

jq_value jq_con(const jq_con_info *info, const jq_value *fields) {
  arity_guard((uint64_t)info->arity + 1, "constructor arity");
  jq_block *b = jq_alloc_block(JQ_CON, 0, (uint16_t)(info->arity + 1));
  b->payload[0] = (uint64_t)info;
  if (info->arity) memcpy(&b->payload[1], fields, (size_t)info->arity * 8);
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
  if (len) memcpy(&b->payload[1], bytes, len);
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
  if (env_n) memcpy(&b->payload[2], env, (size_t)env_n * 8);
  return jq_of_block(b);
}

jq_value jq_con_reuse(jq_block *shell, const jq_con_info *info,
                      const jq_value *fields) {
  if (!shell) return jq_con(info, fields);
  /* same word count guaranteed by the pass (same arity); the pool bit must
     survive the reuse or the shell would later reach libc free (task 80) */
  shell->tag = JQ_CON;
  shell->flags = shell->flags & JQ_FLAG_POOLED;
  shell->rc = 1;
  shell->payload[0] = (uint64_t)info;
  if (info->arity) memcpy(&shell->payload[1], fields, (size_t)info->arity * 8);
  return jq_of_block(shell);
}
