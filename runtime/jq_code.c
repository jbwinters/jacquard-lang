/* Code values (task 73): form construction, structural equality, and the
 * semantic differ — ports of src/form.ml's equal_ignoring_meta and
 * src/diff.ml's form_divergences with src/prelude.ml's rendering. The
 * inline printer lives in jq_show.c beside the escape/real helpers it
 * shares with Value.show. Scope marks are interpreter metadata and have
 * no native counterpart (the plan's task-73 direction: inline printing
 * never shows meta and code.eq? ignores it). */

#include "jq_value.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

jq_value jq_code_node(jq_value head_text, uint16_t argc) {
  if ((uint32_t)1 + 2 * (uint32_t)argc > UINT16_MAX) {
    fputs("jacquard runtime: form arity exceeds the representation\n", stderr);
    exit(2);
  }
  jq_block *b = jq_alloc_block(JQ_CODE, 0, (uint16_t)(1 + 2 * argc));
  b->payload[0] = (uint64_t)head_text;
  return jq_of_block(b);
}

jq_value jq_code_splice_guard(jq_rt *rt, jq_value v) {
  (void)rt;
  if (jq_is_code(v)) return v;
  char *s = jq_show(v);
  fprintf(stderr, "type error: unquote splice evaluated to %s, not code\n", s);
  exit(2);
}

/* --- equal_ignoring_meta ------------------------------------------- */

static bool text_eq(jq_value a, jq_value b) {
  uint64_t la = jq_text_len(a), lb = jq_text_len(b);
  return la == lb && (la == 0 || memcmp(jq_text_bytes(a), jq_text_bytes(b), la) == 0);
}

bool jq_code_eq(jq_value a, jq_value b) {
  if (!text_eq(jq_code_head(a), jq_code_head(b))) return false;
  uint16_t n = jq_code_argc(a);
  if (n != jq_code_argc(b)) return false;
  for (uint16_t i = 0; i < n; i++) {
    uint64_t ka = jq_code_kind(a, i), kb = jq_code_kind(b, i);
    if (ka != kb) return false;
    jq_value da = jq_code_datum(a, i), db = jq_code_datum(b, i);
    switch ((jq_code_kind_t)ka) {
    case JQ_CA_FORM:
      if (!jq_code_eq(da, db)) return false;
      break;
    case JQ_CA_INT:
      if (da != db) return false;
      break;
    case JQ_CA_REAL: {
      /* OCaml Float.compare semantics: nan = nan, -0. = 0. */
      double x = jq_real_val(da), y = jq_real_val(db);
      if (!((x != x && y != y) || x == y)) return false;
      break;
    }
    case JQ_CA_TEXT:
    case JQ_CA_SYM:
      if (!text_eq(da, db)) return false;
      break;
    case JQ_CA_HASH:
      if (memcmp(jq_hash_bytes(da), jq_hash_bytes(db), 32) != 0) return false;
      break;
    }
  }
  return true;
}

/* --- form_divergences (src/diff.ml) with prelude's rendering -------- */

typedef struct {
  char *data;
  size_t len;
  size_t cap;
} dbuf;

static void dbuf_add(dbuf *b, const char *s) {
  size_t n = strlen(s);
  if (b->len + n + 1 > b->cap) {
    b->cap = b->cap ? b->cap : 128;
    while (b->len + n + 1 > b->cap) b->cap *= 2;
    b->data = realloc(b->data, b->cap);
    if (!b->data) {
      fputs("jacquard runtime: out of memory\n", stderr);
      exit(2);
    }
  }
  memcpy(b->data + b->len, s, n);
  b->len += n;
  b->data[b->len] = 0;
}

static char *code_arg_render(uint64_t kind, jq_value datum) {
  if (kind == JQ_CA_FORM) return jq_code_inline(datum);
  return jq_code_scalar(kind, datum);
}

/* one divergence: "at <path>: - <a> + <b>"; [first] threads the "; "
   separator state */
static void emit_div(dbuf *out, bool *first, const char *path, char *ra, char *rb) {
  if (!*first) dbuf_add(out, "; ");
  *first = false;
  dbuf_add(out, "at ");
  dbuf_add(out, path);
  dbuf_add(out, ": - ");
  dbuf_add(out, ra);
  dbuf_add(out, " + ");
  dbuf_add(out, rb);
  free(ra);
  free(rb);
}

static void divergences(dbuf *out, bool *first, const char *path, jq_value fa, jq_value fb) {
  if (jq_code_eq(fa, fb)) return;
  uint16_t n = jq_code_argc(fa);
  if (!text_eq(jq_code_head(fa), jq_code_head(fb)) || n != jq_code_argc(fb)) {
    emit_div(out, first, path, jq_code_inline(fa), jq_code_inline(fb));
    return;
  }
  /* heads and arity agree: recurse into exactly the differing arguments,
     extending the path with "/<head>[i]" */
  jq_value head = jq_code_head(fa);
  for (uint16_t i = 0; i < n; i++) {
    size_t plen = strlen(path) + jq_text_len(head) + 32;
    char *sub = malloc(plen);
    if (!sub) {
      fputs("jacquard runtime: out of memory\n", stderr);
      exit(2);
    }
    snprintf(sub, plen, "%s/%.*s[%u]", path, (int)jq_text_len(head),
             (const char *)jq_text_bytes(head), (unsigned)i);
    uint64_t ka = jq_code_kind(fa, i), kb = jq_code_kind(fb, i);
    jq_value da = jq_code_datum(fa, i), db = jq_code_datum(fb, i);
    if (ka == JQ_CA_FORM && kb == JQ_CA_FORM) divergences(out, first, sub, da, db);
    else {
      /* scalar (or mixed) position: report unless equal (equal_arg) */
      bool eq = false;
      if (ka == kb) {
        switch ((jq_code_kind_t)ka) {
        case JQ_CA_INT: eq = da == db; break;
        case JQ_CA_REAL: {
          double x = jq_real_val(da), y = jq_real_val(db);
          eq = (x != x && y != y) || x == y;
          break;
        }
        case JQ_CA_TEXT:
        case JQ_CA_SYM: eq = text_eq(da, db); break;
        case JQ_CA_HASH: eq = memcmp(jq_hash_bytes(da), jq_hash_bytes(db), 32) == 0; break;
        case JQ_CA_FORM: break; /* unreachable: handled above */
        }
      }
      if (!eq) emit_div(out, first, sub, code_arg_render(ka, da), code_arg_render(kb, db));
    }
    free(sub);
  }
}

/* code.diff's text: "identical" or the "; "-joined divergences, rooted at
   the interpreter's fixed "log" path (src/prelude.ml) */
char *jq_code_diff_render(jq_value a, jq_value b) {
  dbuf out = { 0 };
  bool first = true;
  divergences(&out, &first, "log", a, b);
  if (out.len == 0) {
    dbuf_add(&out, "identical");
  }
  return out.data;
}
