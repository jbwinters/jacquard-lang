/* Perceus reference counting (task 65): dup, drop, and the reuse token.
 *
 * jq_drop frees with an explicit heap worklist, never C recursion — a
 * 10M-element list drop must run in bounded C stack. The walk skips a
 * closure's non-owning self slot (the cycle rule; see jq_value.h). */

#include "jq_value.h"

#include <stdio.h>
#include <stdlib.h>

void jq_dup(jq_value v) {
  if (jq_is_int(v)) return;
  jq_block *b = jq_block_of(v);
  if (b->rc != JQ_RC_STATIC) b->rc++;
}

/* Owned child fields of a block, by tag: TEXT/REAL/HASH have none; the
 * static-only tags (CONSTRUCTOR/OP/BUILTIN) never reach the free walk. */

typedef struct {
  jq_block **items;
  size_t len;
  size_t cap;
} worklist;

static void wl_push(worklist *w, jq_block *b) {
  if (w->len == w->cap) {
    w->cap = w->cap ? w->cap * 2 : 64;
    w->items = realloc(w->items, w->cap * sizeof(jq_block *));
    if (!w->items) {
      fputs("jacquard runtime: out of memory\n", stderr);
      exit(2);
    }
  }
  w->items[w->len++] = b;
}

/* Decrement a child; a zeroed child joins the worklist. */
static void drop_child(worklist *w, jq_value v) {
  if (jq_is_int(v)) return;
  jq_block *b = jq_block_of(v);
  if (b->rc == JQ_RC_STATIC) return;
  if (--b->rc == 0) wl_push(w, b);
}

static void free_walk(jq_block *root) {
  worklist w = { 0 };
  wl_push(&w, root);
  while (w.len > 0) {
    jq_block *b = w.items[--w.len];
    switch (b->tag) {
    case JQ_TUPLE:
      for (uint16_t i = 0; i < b->n; i++) drop_child(&w, b->payload[i]);
      break;
    case JQ_CON:
      for (uint16_t i = 1; i < b->n; i++) drop_child(&w, b->payload[i]);
      break;
    case JQ_CLOSURE: {
      int32_t self = -1;
      if (b->flags & JQ_FLAG_SELF_SLOT)
        self = (int32_t)((b->payload[1] >> 16) & 0xffffffff) - 1;
      for (uint16_t i = 2; i < b->n; i++)
        if ((int32_t)(i - 2) != self) drop_child(&w, b->payload[i]);
      break;
    }
    case JQ_TEXT:
    case JQ_REAL:
    case JQ_HASH:
      break;
    default:
      /* CODE/RESUME arrive with tasks 73/71 and extend this walk;
         static-only tags cannot be freed */
      fprintf(stderr, "jacquard runtime: free walk hit tag %d\n", b->tag);
      exit(2);
    }
    free(b);
  }
  free(w.items);
}

void jq_drop(jq_value v) {
  if (jq_is_int(v)) return;
  jq_block *b = jq_block_of(v);
  if (b->rc == JQ_RC_STATIC) return;
  if (--b->rc == 0) free_walk(b);
}

jq_block *jq_drop_reuse(jq_value v) {
  if (jq_is_int(v)) return NULL;
  jq_block *b = jq_block_of(v);
  if (b->rc == JQ_RC_STATIC) return NULL;
  if (b->rc == 1) return b; /* caller owns the shell AND its fields now */
  b->rc--;
  return NULL;
}
