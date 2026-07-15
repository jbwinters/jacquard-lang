/* Copyright (C) 2026 Josh Winters
 * SPDX-License-Identifier: Apache-2.0
 * Additional permission applies; see ../RUNTIME-EXCEPTION.md. */

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

/* Value.show VHash and Printer's hash scalar spelling are identical: one '#'
 * followed by the fixed 32-byte digest as 64 lowercase hexadecimal digits. */
static void add_hash_repr(jq_buf *b, jq_value hash) {
  static const char hex[] = "0123456789abcdef";
  const uint8_t *bytes = jq_hash_bytes(hash);
  char rendered[65];
  rendered[0] = '#';
  for (size_t i = 0; i < 32; i++) {
    rendered[1 + (i * 2)] = hex[bytes[i] >> 4];
    rendered[2 + (i * 2)] = hex[bytes[i] & 0x0f];
  }
  buf_add(b, rendered, sizeof rendered);
}

/* --- the canonical inline printer (task 73; src/printer.ml) --------- */

/* Reader.valid_head: [a-z][a-z0-9-]* */
static bool head_ok(const uint8_t *s, uint64_t n) {
  if (n == 0 || s[0] < 'a' || s[0] > 'z') return false;
  for (uint64_t i = 0; i < n; i++) {
    uint8_t c = s[i];
    if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')) return false;
  }
  return true;
}

/* Reader.valid_library_symbol: dot-separated [a-z][a-z0-9-]* segments,
   at most one trailing ? or ! */
static bool symbol_ok(const uint8_t *s, uint64_t n) {
  if (n == 0) return false;
  uint64_t body = (s[n - 1] == '?' || s[n - 1] == '!') ? n - 1 : n;
  if (body == 0) return false;
  uint64_t seg = 0;
  for (uint64_t i = 0; i <= body; i++) {
    if (i == body || s[i] == '.') {
      if (seg == i) return false; /* empty segment */
      if (!(s[seg] >= 'a' && s[seg] <= 'z')) return false;
      seg = i + 1;
    } else {
      uint8_t c = s[i];
      if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')) return false;
    }
  }
  return true;
}

/* Printer.Bug_unprintable parity: the interpreter raises out of Value.show;
   unreachable from checked programs (quote payloads parsed, code.form heads
   validated), so the native rendering of the crash is a plain fatal. */
static void unprintable(const char *what, const uint8_t *s, uint64_t n) {
  fprintf(stderr, "jacquard runtime: %s %.*s is not printable\n", what, (int)n,
          (const char *)s);
  exit(2);
}

static void scalar_into(jq_buf *b, uint64_t kind, jq_value datum) {
  switch ((jq_code_kind_t)kind) {
  case JQ_CA_INT:
    buf_addf(b, "%lld", (long long)jq_int_val(datum));
    break;
  case JQ_CA_REAL:
    add_real_repr(b, jq_real_val(datum));
    break;
  case JQ_CA_TEXT:
    add_escaped_text(b, jq_text_bytes(datum), jq_text_len(datum));
    break;
  case JQ_CA_SYM: {
    const uint8_t *s = jq_text_bytes(datum);
    uint64_t n = jq_text_len(datum);
    if (!symbol_ok(s, n)) unprintable("symbol", s, n);
    buf_add(b, (const char *)s, n);
    break;
  }
  case JQ_CA_HASH: {
    add_hash_repr(b, datum);
    break;
  }
  case JQ_CA_FORM:
    jq_runtime_error("jacquard runtime: scalar rendering hit a form (internal)");
  }
}

static void inline_form_into(jq_buf *b, jq_value code) {
  jq_value head = jq_code_head(code);
  const uint8_t *hs = jq_text_bytes(head);
  uint64_t hn = jq_text_len(head);
  uint16_t argc = jq_code_argc(code);
  bool group = hn == 5 && memcmp(hs, "group", 5) == 0;
  buf_adds(b, "(");
  if (group) {
    /* a group whose first element is a scalar reparses as a headed form */
    if (argc > 0 && jq_code_kind(code, 0) != JQ_CA_FORM)
      unprintable("group with a leading scalar element", hs, hn);
  } else {
    if (!head_ok(hs, hn)) unprintable("head", hs, hn);
    buf_add(b, (const char *)hs, hn);
  }
  for (uint16_t i = 0; i < argc; i++) {
    if (i || !group) buf_adds(b, " ");
    if (jq_code_kind(code, i) == JQ_CA_FORM) inline_form_into(b, jq_code_datum(code, i));
    else scalar_into(b, jq_code_kind(code, i), jq_code_datum(code, i));
  }
  buf_adds(b, ")");
}

char *jq_code_inline(jq_value v) {
  jq_buf b = { 0 };
  buf_grow(&b, 16);
  b.data[0] = 0;
  inline_form_into(&b, v);
  return b.data;
}

char *jq_code_scalar(uint64_t kind, jq_value datum) {
  jq_buf b = { 0 };
  buf_grow(&b, 16);
  b.data[0] = 0;
  scalar_into(&b, kind, datum);
  return b.data;
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
  case JQ_HASH:
    add_hash_repr(b, v);
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
  case JQ_CODE:
    /* Value.show: "(quote " ^ Printer.inline_form payload ^ ")" */
    buf_adds(b, "(quote ");
    inline_form_into(b, v);
    buf_adds(b, ")");
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
