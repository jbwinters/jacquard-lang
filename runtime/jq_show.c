/* Value rendering (task 66): a byte-for-byte port of the interpreter's
 * Value.show (src/value.ml) and Printer.real_repr / escape_text
 * (src/printer.ml). Parity is pinned by corpus/golden/native/show.golden;
 * any divergence is a bug HERE, never in the golden.
 *
 * CODE rendering ("(quote <inline form>)") lands with the form
 * representation in task 73; until then a CODE block aborts loudly.
 * Real formatting leans on libc printf/strtod matching OCaml's — a same-
 * platform property, re-verified per toolchain in task 76. */

#include "jq_value.h"

#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* growable byte buffer */
typedef struct {
  char *data;
  size_t len;
  size_t cap;
} jq_buf;

static void buf_grow(jq_buf *b, size_t need) {
  if (b->len + need + 1 > b->cap) {
    b->cap = b->cap ? b->cap : 64;
    while (b->len + need + 1 > b->cap) b->cap *= 2;
    b->data = realloc(b->data, b->cap);
    if (!b->data) jq_runtime_error("jacquard runtime: out of memory");
  }
}

static void buf_add(jq_buf *b, const char *s, size_t n) {
  buf_grow(b, n);
  memcpy(b->data + b->len, s, n);
  b->len += n;
  b->data[b->len] = 0;
}

static void buf_adds(jq_buf *b, const char *s) { buf_add(b, s, strlen(s)); }

static void buf_addf(jq_buf *b, const char *fmt, ...)
    __attribute__((format(printf, 2, 3)));
static void buf_addf(jq_buf *b, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  va_list ap2;
  va_copy(ap2, ap);
  int n = vsnprintf(NULL, 0, fmt, ap);
  va_end(ap);
  buf_grow(b, (size_t)n);
  vsnprintf(b->data + b->len, (size_t)n + 1, fmt, ap2);
  va_end(ap2);
  b->len += (size_t)n;
}

/* Printer.real_repr: shortest of %.15g/%.16g/%.17g that reparses to the
 * identical double; Scheme spellings for non-finite; a ".0" suffix when the
 * candidate has no '.', 'e', or 'E'. */
static void add_real_repr(jq_buf *b, double r) {
  if (isnan(r)) {
    buf_adds(b, "+nan.0");
    return;
  }
  if (isinf(r)) {
    buf_adds(b, r > 0 ? "+inf.0" : "-inf.0");
    return;
  }
  char cand[32];
  snprintf(cand, sizeof cand, "%.15g", r);
  if (strtod(cand, NULL) != r) {
    snprintf(cand, sizeof cand, "%.16g", r);
    if (strtod(cand, NULL) != r) snprintf(cand, sizeof cand, "%.17g", r);
  }
  buf_adds(b, cand);
  if (!strpbrk(cand, ".eE")) buf_adds(b, ".0");
}

/* Printer.escape_text: quote, backslash, \n \t \r, \xNN for other control
 * bytes and 0x7f; everything else (including non-ASCII bytes) verbatim. */
static void add_escaped_text(jq_buf *b, const uint8_t *s, uint64_t n) {
  buf_adds(b, "\"");
  for (uint64_t i = 0; i < n; i++) {
    uint8_t c = s[i];
    switch (c) {
    case '"': buf_adds(b, "\\\""); break;
    case '\\': buf_adds(b, "\\\\"); break;
    case '\n': buf_adds(b, "\\n"); break;
    case '\t': buf_adds(b, "\\t"); break;
    case '\r': buf_adds(b, "\\r"); break;
    default:
      if (c < 0x20 || c == 0x7f) buf_addf(b, "\\x%02x", c);
      else buf_add(b, (const char *)&c, 1);
    }
  }
  buf_adds(b, "\"");
}

static void show_into(jq_buf *b, jq_value v) {
  if (jq_is_int(v)) {
    buf_addf(b, "%lld", (long long)jq_int_val(v));
    return;
  }
  jq_block *blk = jq_block_of(v);
  switch (blk->tag) {
  case JQ_REAL:
    add_real_repr(b, jq_real_val(v));
    break;
  case JQ_TEXT:
    add_escaped_text(b, jq_text_bytes(v), jq_text_len(v));
    break;
  case JQ_TUPLE:
    buf_adds(b, "(");
    for (uint16_t i = 0; i < blk->n; i++) {
      if (i) buf_adds(b, ", ");
      show_into(b, jq_fields(v)[i]);
    }
    buf_adds(b, ")");
    break;
  case JQ_CON: {
    const jq_con_info *info = jq_con_info_of(v);
    buf_adds(b, info->name);
    if (jq_con_arity(v) > 0) {
      buf_adds(b, "(");
      for (uint16_t i = 0; i < jq_con_arity(v); i++) {
        if (i) buf_adds(b, ", ");
        show_into(b, jq_con_fields(v)[i]);
      }
      buf_adds(b, ")");
    }
    break;
  }
  case JQ_CLOSURE:
    buf_adds(b, "<closure>");
    break;
  case JQ_CONSTRUCTOR: {
    const jq_con_info *info = (const jq_con_info *)blk->payload[0];
    buf_addf(b, "<constructor %s/%u>", info->name, info->arity);
    break;
  }
  case JQ_OP: {
    const jq_op_info *info = (const jq_op_info *)blk->payload[0];
    buf_addf(b, "<op %s.%s>", info->effect_name, info->op_name);
    break;
  }
  case JQ_BUILTIN: {
    const jq_builtin_info *info = (const jq_builtin_info *)blk->payload[0];
    buf_addf(b, "<builtin %s>", info->name);
    break;
  }
  case JQ_RESUME:
    buf_adds(b, "<resume>");
    break;
  default:
    jq_runtime_error("jacquard runtime: show hit an unrenderable tag");
  }
}

/* Render like Value.show; the caller frees the returned string. */
char *jq_show(jq_value v) {
  jq_buf b = { 0 };
  buf_grow(&b, 16);
  b.data[0] = 0;
  show_into(&b, v);
  return b.data;
}
