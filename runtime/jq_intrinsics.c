/* Copyright (C) 2026 Josh Winters
 * SPDX-License-Identifier: Apache-2.0
 * Additional permission applies; see ../RUNTIME-EXCEPTION.md. */

/* Builtin intrinsics (task 67): the native implementations of the prelude's
 * marker builtins, ported from Prelude.wire_builtins (src/prelude.ml) with
 * the interpreter's exact behaviors and error texts. Every intrinsic
 * CONSUMES its arguments (no-ops for ints/statics); type errors render like
 * Runtime_err.Type_error ("type error: <name> expects ..., got <shows>")
 * and exit 2. docs/native-intrinsics.md tracks coverage. */

#include "jq_value.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void type_err2(const char *name, const char *kind, jq_value a, jq_value b)
    __attribute__((noreturn));
static void type_err2(const char *name, const char *kind, jq_value a, jq_value b) {
  char *sa = jq_show(a), *sb = jq_show(b);
  fprintf(stderr, "type error: %s expects two %s, got %s, %s\n", name, kind, sa, sb);
  exit(2);
}

static bool is_real(jq_value v) {
  return jq_is_ptr(v) && jq_block_of(v)->tag == JQ_REAL;
}
static bool is_text(jq_value v) {
  return jq_is_ptr(v) && jq_block_of(v)->tag == JQ_TEXT;
}

static jq_value vbool(jq_rt *rt, bool b) {
  return b ? rt->v_true : rt->v_false; /* statics; no dup needed */
}

#define INT2(name)                                                             \
  if (!jq_is_int(a[0]) || !jq_is_int(a[1])) type_err2(name, "ints", a[0], a[1])

jq_value jq_i_add(jq_rt *rt, const jq_value *a) {
  (void)rt;
  INT2("add");
  return jq_int_add(a[0], a[1]);
}
jq_value jq_i_sub(jq_rt *rt, const jq_value *a) {
  (void)rt;
  INT2("sub");
  return jq_int_sub(a[0], a[1]);
}
jq_value jq_i_mul(jq_rt *rt, const jq_value *a) {
  (void)rt;
  INT2("mul");
  return jq_int_mul(a[0], a[1]);
}
jq_value jq_i_div(jq_rt *rt, const jq_value *a) {
  (void)rt;
  INT2("div");
  return jq_int_div_checked(a[0], a[1]);
}
jq_value jq_i_mod(jq_rt *rt, const jq_value *a) {
  (void)rt;
  INT2("mod");
  return jq_int_mod_checked(a[0], a[1]);
}
jq_value jq_i_eq(jq_rt *rt, const jq_value *a) {
  INT2("eq");
  return vbool(rt, a[0] == a[1]);
}
jq_value jq_i_lt(jq_rt *rt, const jq_value *a) {
  INT2("lt");
  return vbool(rt, jq_int_val(a[0]) < jq_int_val(a[1]));
}

#define REAL2(name)                                                            \
  if (!is_real(a[0]) || !is_real(a[1])) type_err2(name, "reals", a[0], a[1])

static jq_value real2(jq_value x, jq_value y, double r) {
  jq_drop(x);
  jq_drop(y);
  return jq_real(r);
}

jq_value jq_i_add_real(jq_rt *rt, const jq_value *a) {
  (void)rt;
  REAL2("real.add");
  return real2(a[0], a[1], jq_real_val(a[0]) + jq_real_val(a[1]));
}
jq_value jq_i_sub_real(jq_rt *rt, const jq_value *a) {
  (void)rt;
  REAL2("real.sub");
  return real2(a[0], a[1], jq_real_val(a[0]) - jq_real_val(a[1]));
}
jq_value jq_i_mul_real(jq_rt *rt, const jq_value *a) {
  (void)rt;
  REAL2("real.mul");
  return real2(a[0], a[1], jq_real_val(a[0]) * jq_real_val(a[1]));
}
jq_value jq_i_div_real(jq_rt *rt, const jq_value *a) {
  (void)rt;
  REAL2("real.div");
  /* IEEE division: the interpreter divides OCaml floats, inf/nan included */
  return real2(a[0], a[1], jq_real_val(a[0]) / jq_real_val(a[1]));
}
static jq_value real_predicate(jq_rt *rt, const jq_value *a, bool r) {
  jq_drop(a[0]);
  jq_drop(a[1]);
  return vbool(rt, r);
}

jq_value jq_i_lt_real(jq_rt *rt, const jq_value *a) {
  REAL2("real.lt?");
  return real_predicate(rt, a, jq_real_val(a[0]) < jq_real_val(a[1]));
}
jq_value jq_i_real_gt_q(jq_rt *rt, const jq_value *a) {
  REAL2("real.gt?");
  return real_predicate(rt, a, jq_real_val(a[0]) > jq_real_val(a[1]));
}
jq_value jq_i_real_gte_q(jq_rt *rt, const jq_value *a) {
  REAL2("real.gte?");
  return real_predicate(rt, a, jq_real_val(a[0]) >= jq_real_val(a[1]));
}
jq_value jq_i_real_lte_q(jq_rt *rt, const jq_value *a) {
  REAL2("real.lte?");
  return real_predicate(rt, a, jq_real_val(a[0]) <= jq_real_val(a[1]));
}

jq_value jq_i_text_length(jq_rt *rt, const jq_value *a) {
  (void)rt;
  if (!is_text(a[0])) {
    char *s = jq_show(a[0]);
    fprintf(stderr, "type error: text.length got unexpected arguments %s\n", s);
    exit(2);
  }
  jq_value r = jq_int((int64_t)jq_utf8_count(jq_text_bytes(a[0]), jq_text_len(a[0])));
  jq_drop(a[0]);
  return r;
}

static void type_err_args(const char *name, const jq_value *a, uint16_t n)
    __attribute__((noreturn));
static bool is_con_named(jq_value v, const char *name);

jq_value jq_i_text_concat(jq_rt *rt, const jq_value *a) {
  (void)rt;
  /* the interpreter's text2 wrapper uses the generic rendering, not the
     "expects two texts" form (review find via the row-erasure probes) */
  if (!is_text(a[0]) || !is_text(a[1])) type_err_args("text.concat", a, 2);
  uint64_t la = jq_text_len(a[0]), lb = jq_text_len(a[1]);
  uint8_t *tmp = malloc(la + lb ? la + lb : 1);
  if (!tmp) jq_runtime_error("jacquard runtime: out of memory");
  memcpy(tmp, jq_text_bytes(a[0]), la);
  memcpy(tmp + la, jq_text_bytes(a[1]), lb);
  jq_value r = jq_text(tmp, la + lb);
  free(tmp);
  jq_drop(a[0]);
  jq_drop(a[1]);
  return r;
}

static void text_join_list_error(const jq_value *a, jq_value bad)
    __attribute__((noreturn));
static void text_join_list_error(const jq_value *a, jq_value bad) {
  char *shown = jq_show(bad);
  fprintf(stderr, "type error: text.join expects a list of texts, got %s\n", shown);
  free(shown);
  jq_drop(a[0]);
  jq_drop(a[1]);
  exit(2);
}

jq_value jq_i_text_join(jq_rt *rt, const jq_value *a) {
  (void)rt;
  if (!is_text(a[1])) type_err_args("text.join", a, 2);
  uint64_t count = 0, text_total = 0;
  jq_value it = a[0];
  while (is_con_named(it, "cons") && jq_con_arity(it) == 2) {
    jq_value head = jq_con_fields(it)[0];
    if (!is_text(head)) text_join_list_error(a, it);
    text_total += jq_text_len(head);
    count++;
    it = jq_con_fields(it)[1];
  }
  if (!(is_con_named(it, "nil") && jq_con_arity(it) == 0)) text_join_list_error(a, it);
  uint64_t separator_len = jq_text_len(a[1]);
  uint64_t total = text_total + (count > 0 ? (count - 1) * separator_len : 0);
  uint8_t *tmp = total ? malloc(total) : NULL;
  if (total && !tmp) jq_runtime_error("jacquard runtime: out of memory");
  uint64_t offset = 0, index = 0;
  for (it = a[0]; is_con_named(it, "cons"); it = jq_con_fields(it)[1], index++) {
    if (index > 0) {
      memcpy(tmp + offset, jq_text_bytes(a[1]), separator_len);
      offset += separator_len;
    }
    jq_value head = jq_con_fields(it)[0];
    uint64_t length = jq_text_len(head);
    memcpy(tmp + offset, jq_text_bytes(head), length);
    offset += length;
  }
  jq_value result = jq_text(total ? tmp : (const uint8_t *)"", total);
  free(tmp);
  jq_drop(a[0]);
  jq_drop(a[1]);
  return result;
}

jq_value jq_i_text_join_variadic_v1(jq_rt *rt, const jq_value *a, uint16_t n) {
  (void)rt;
  uint64_t total = 0;
  for (uint16_t i = 0; i < n; i++) {
    if (!is_text(a[i])) {
      char *shown = jq_show(a[i]);
      fprintf(stderr, "type error: text.join expects Text at argument %u, got %s\n",
              (unsigned)(i + 1), shown);
      free(shown);
      for (uint16_t j = 0; j < n; j++) jq_drop(a[j]);
      exit(2);
    }
    total += jq_text_len(a[i]);
  }
  uint8_t *tmp = total ? malloc(total) : NULL;
  if (total && !tmp) jq_runtime_error("jacquard runtime: out of memory");
  uint64_t offset = 0;
  for (uint16_t i = 0; i < n; i++) {
    uint64_t length = jq_text_len(a[i]);
    memcpy(tmp + offset, jq_text_bytes(a[i]), length);
    offset += length;
  }
  jq_value result = jq_text(total ? tmp : (const uint8_t *)"", total);
  free(tmp);
  for (uint16_t i = 0; i < n; i++) jq_drop(a[i]);
  return result;
}

static jq_value vord(jq_rt *rt, int c) {
  return c < 0 ? rt->v_less : c == 0 ? rt->v_equal : rt->v_greater;
}

jq_value jq_i_int_compare(jq_rt *rt, const jq_value *a) {
  INT2("int-compare");
  int64_t x = jq_int_val(a[0]), y = jq_int_val(a[1]);
  return vord(rt, x < y ? -1 : x > y ? 1 : 0);
}

/* bytewise = codepoint order for UTF-8 (SL.5); OCaml compare on strings is
   bytewise with length tiebreak, same as memcmp-then-length */
jq_value jq_i_text_compare(jq_rt *rt, const jq_value *a) {
  if (!is_text(a[0]) || !is_text(a[1])) type_err2("text-compare", "texts", a[0], a[1]);
  uint64_t la = jq_text_len(a[0]), lb = jq_text_len(a[1]);
  uint64_t m = la < lb ? la : lb;
  int c = m ? memcmp(jq_text_bytes(a[0]), jq_text_bytes(a[1]), m) : 0;
  if (c == 0) c = la < lb ? -1 : la > lb ? 1 : 0;
  jq_drop(a[0]);
  jq_drop(a[1]);
  return vord(rt, c);
}

static void type_err_args(const char *name, const jq_value *a, uint16_t n)
    __attribute__((noreturn));
static void type_err_args(const char *name, const jq_value *a, uint16_t n) {
  fprintf(stderr, "type error: %s got unexpected arguments ", name);
  for (uint16_t i = 0; i < n; i++) {
    char *s = jq_show(a[i]);
    fprintf(stderr, "%s%s", i ? ", " : "", s);
    free(s);
  }
  fputc('\n', stderr);
  for (uint16_t i = 0; i < n; i++) jq_drop(a[i]);
  exit(2);
}

/* ASCII whitespace only in this draft, matching the interpreter (documented) */
jq_value jq_i_text_trim(jq_rt *rt, const jq_value *a) {
  (void)rt;
  if (!is_text(a[0])) type_err_args("text.trim", a, 1);
  const uint8_t *s = jq_text_bytes(a[0]);
  uint64_t n = jq_text_len(a[0]);
  uint64_t i = 0, j = n;
  while (i < j && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) i++;
  while (j > i && (s[j - 1] == ' ' || s[j - 1] == '\t' || s[j - 1] == '\n' || s[j - 1] == '\r'))
    j--;
  jq_value r = jq_text(s + i, j - i);
  jq_drop(a[0]);
  return r;
}

static jq_value cons2(jq_rt *rt, jq_value x, jq_value rest) {
  return jq_con(rt->ci_cons, (jq_value[]){ x, rest });
}

/* Non-empty separator: non-overlapping left-to-right scan, empty pieces kept
 * (leading/trailing/adjacent). Empty separator: singleton-codepoint pieces.
 * Ported from Prelude's text.split. */
jq_value jq_i_text_split(jq_rt *rt, const jq_value *a) {
  if (!is_text(a[0]) || !is_text(a[1])) type_err_args("text.split", a, 2);
  const uint8_t *s = jq_text_bytes(a[0]);
  uint64_t n = jq_text_len(a[0]);
  const uint8_t *sep = jq_text_bytes(a[1]);
  uint64_t pn = jq_text_len(a[1]);
  /* gather (start, len) pieces, then build the list back-to-front */
  uint64_t cap = 16, count = 0;
  uint64_t *starts = malloc(cap * sizeof(uint64_t));
  uint64_t *lens = malloc(cap * sizeof(uint64_t));
  if (!starts || !lens) jq_runtime_error("jacquard runtime: out of memory");
#define PUSH_PIECE(st_, ln_)                                                   \
  do {                                                                         \
    if (count == cap) {                                                        \
      cap *= 2;                                                                \
      starts = realloc(starts, cap * sizeof(uint64_t));                        \
      lens = realloc(lens, cap * sizeof(uint64_t));                            \
      if (!starts || !lens) jq_runtime_error("jacquard runtime: out of memory"); \
    }                                                                          \
    starts[count] = (st_);                                                     \
    lens[count] = (ln_);                                                       \
    count++;                                                                   \
  } while (0)
  if (pn == 0) {
    for (uint64_t i = 0; i < n;) {
      uint64_t w = jq_utf8_width(s, n, i);
      PUSH_PIECE(i, w);
      i += w;
    }
  } else {
    uint64_t start = 0, i = 0;
    while (i + pn <= n) {
      if (memcmp(s + i, sep, pn) == 0) {
        PUSH_PIECE(start, i - start);
        start = i + pn;
        i += pn;
      } else i++;
    }
    PUSH_PIECE(start, n - start);
  }
#undef PUSH_PIECE
  jq_value list = rt->v_nil;
  for (uint64_t k = count; k > 0; k--)
    list = cons2(rt, jq_text(s + starts[k - 1], lens[k - 1]), list);
  free(starts);
  free(lens);
  jq_drop(a[0]);
  jq_drop(a[1]);
  return list;
}

jq_value jq_i_text_empty_q(jq_rt *rt, const jq_value *a) {
  if (!is_text(a[0])) type_err_args("text.empty?", a, 1);
  bool r = jq_text_len(a[0]) == 0;
  jq_drop(a[0]);
  return vbool(rt, r);
}

jq_value jq_i_text_from_int(jq_rt *rt, const jq_value *a) {
  (void)rt;
  if (!jq_is_int(a[0])) type_err_args("text.from-int", a, 1);
  char buf[32];
  int n = snprintf(buf, sizeof buf, "%lld", (long long)jq_int_val(a[0]));
  return jq_text((const uint8_t *)buf, (uint64_t)n);
}

/* --- dist intrinsics (task 71: the enum handler's builtins) ---
 *
 * Distribution values are prelude constructor data, recognized BY NAME like
 * the interpreter's Infer_dist.dist_of_value: bernoulli(real),
 * categorical(list of mk-pair(x, real)), uniform-int(lo, hi). Errors render
 * as the interpreter's Runtime_err (arithmetic/type), exit 2. */

static bool is_con_named(jq_value v, const char *name) {
  return jq_is_ptr(v) && jq_block_of(v)->tag == JQ_CON &&
         strcmp(jq_con_info_of(v)->name, name) == 0;
}

static void arith_err(const char *fmt, ...) __attribute__((noreturn, format(printf, 1, 2)));
static void arith_err(const char *fmt, ...) {
  va_list ap;
  fputs("arithmetic error: ", stderr);
  va_start(ap, fmt);
  vfprintf(stderr, fmt, ap);
  va_end(ap);
  fputc('\n', stderr);
  exit(2);
}

static jq_value pair2(jq_rt *rt, jq_value x, jq_value p) {
  return jq_con(rt->ci_pair, (jq_value[]){ x, p });
}

/* validate a categorical's entries list; interpreter's entries_of */
static void check_entries(jq_value entries) {
  jq_value v = entries;
  while (true) {
    if (is_con_named(v, "nil")) return;
    if (is_con_named(v, "cons")) {
      jq_value head = jq_con_fields(v)[0];
      if (is_con_named(head, "mk-pair") &&
          jq_is_ptr(jq_con_fields(head)[1]) &&
          jq_block_of(jq_con_fields(head)[1])->tag == JQ_REAL) {
        v = jq_con_fields(v)[1];
        continue;
      }
    }
    char *s = jq_show(v);
    fprintf(stderr, "type error: categorical expects a list of pairs, got %s\n", s);
    exit(2);
  }
}

/* interpreter's dist_of_value validation, without building the OCaml view */
static void check_dist(jq_value d) {
  if (is_con_named(d, "bernoulli") && jq_is_ptr(jq_con_fields(d)[0]) &&
      jq_block_of(jq_con_fields(d)[0])->tag == JQ_REAL) {
    double p = jq_real_val(jq_con_fields(d)[0]);
    if (p < 0.0 || p > 1.0 || p != p)
      arith_err("bernoulli parameter %g is not in [0, 1]", p);
    return;
  }
  if (is_con_named(d, "categorical")) {
    check_entries(jq_con_fields(d)[0]);
    return;
  }
  if (is_con_named(d, "uniform-int") && jq_is_int(jq_con_fields(d)[0]) &&
      jq_is_int(jq_con_fields(d)[1])) {
    int64_t lo = jq_int_val(jq_con_fields(d)[0]);
    int64_t hi = jq_int_val(jq_con_fields(d)[1]);
    if (hi < lo)
      arith_err("uniform-int range %lld..%lld is empty", (long long)lo, (long long)hi);
    return;
  }
  char *s = jq_show(d);
  fprintf(stderr, "type error: %s is not a distribution value\n", s);
  exit(2);
}

/* the support list, owned; the caller validated the dist. uniform-int is
 * budget-capped exactly like the interpreter. */
static jq_value support_of(jq_rt *rt, jq_value d) {
  if (is_con_named(d, "bernoulli")) {
    double p = jq_real_val(jq_con_fields(d)[0]);
    jq_value tail = jq_con(rt->ci_cons, (jq_value[]){ pair2(rt, rt->v_false, jq_real(1.0 - p)),
                                                      rt->v_nil });
    return jq_con(rt->ci_cons, (jq_value[]){ pair2(rt, rt->v_true, jq_real(p)), tail });
  }
  if (is_con_named(d, "categorical")) {
    jq_value entries = jq_con_fields(d)[0];
    jq_dup(entries);
    return entries;
  }
  /* uniform-int */
  int64_t lo = jq_int_val(jq_con_fields(d)[0]);
  int64_t hi = jq_int_val(jq_con_fields(d)[1]);
  int64_t n = hi - lo + 1;
  if (n > 10000)
    arith_err("uniform-int %lld..%lld has %lld outcomes; enumeration caps at 10000",
              (long long)lo, (long long)hi, (long long)n);
  double p = 1.0 / (double)n;
  jq_value list = rt->v_nil;
  for (int64_t i = n - 1; i >= 0; i--)
    list = jq_con(rt->ci_cons, (jq_value[]){ pair2(rt, jq_int(lo + i), jq_real(p)), list });
  return list;
}

/* --- code intrinsics (task 73): structural ops over quoted forms ---- */

static jq_value vsome(jq_rt *rt, jq_value v) { return jq_con(rt->ci_some, (jq_value[]){ v }); }

/* the one static text the code intrinsics need: "lit" (of-int builds
   (lit n) nodes). TEXT layout: n=2 words (length word + one data word). */
static struct {
  uint32_t rc;
  uint8_t tag;
  uint8_t flags;
  uint16_t n;
  uint64_t len;
  char bytes[8];
} jq_lit_text = { JQ_RC_STATIC, JQ_TEXT, 0, 2, 3, "lit" };
#define JQ_LIT_TEXT ((jq_value)&jq_lit_text)

static struct {
  uint32_t rc;
  uint8_t tag;
  uint8_t flags;
  uint16_t n;
  uint64_t len;
  char bytes[8];
} jq_hash_text = { JQ_RC_STATIC, JQ_TEXT, 0, 2, 4, "hash" };
#define JQ_HASH_TEXT ((jq_value)&jq_hash_text)

jq_value jq_i_code_of_int(jq_rt *rt, const jq_value *a) {
  (void)rt;
  if (!jq_is_int(a[0])) type_err_args("code.of-int", a, 1);
  jq_value node = jq_code_node(JQ_LIT_TEXT, 1);
  jq_code_set(node, 0, JQ_CA_INT, a[0]);
  return node;
}

jq_value jq_i_code_of_real(jq_rt *rt, const jq_value *a) {
  (void)rt;
  if (!is_real(a[0])) type_err_args("code.of-real", a, 1);
  jq_value node = jq_code_node(JQ_LIT_TEXT, 1);
  jq_code_set(node, 0, JQ_CA_REAL, a[0]);
  return node;
}

jq_value jq_i_code_of_hash(jq_rt *rt, const jq_value *a) {
  (void)rt;
  if (!jq_is_hash(a[0])) type_err_args("code.of-hash", a, 1);
  jq_value node = jq_code_node(JQ_HASH_TEXT, 1);
  jq_code_set(node, 0, JQ_CA_HASH, a[0]);
  return node;
}

jq_value jq_i_code_of_text(jq_rt *rt, const jq_value *a) {
  (void)rt;
  if (!is_text(a[0])) type_err_args("code.of-text", a, 1);
  jq_value node = jq_code_node(JQ_LIT_TEXT, 1);
  jq_code_set(node, 0, JQ_CA_TEXT, a[0]);
  return node;
}

static int lowercase_hex(uint8_t c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  return -1;
}

jq_value jq_i_hash_parse(jq_rt *rt, const jq_value *a) {
  if (!is_text(a[0])) type_err_args("hash.parse", a, 1);
  const uint8_t *spelling = jq_text_bytes(a[0]);
  uint64_t n = jq_text_len(a[0]);
  uint8_t bytes[32];
  bool valid = n == 64;
  if (valid) {
    for (uint64_t i = 0; i < 32; i++) {
      int high = lowercase_hex(spelling[2 * i]);
      int low = lowercase_hex(spelling[2 * i + 1]);
      if (high < 0 || low < 0) {
	valid = false;
	break;
      }
      bytes[i] = (uint8_t)((high << 4) | low);
    }
  }
  jq_drop(a[0]);
  if (valid) return jq_con(rt->ci_ok, (jq_value[]){ jq_hash(bytes) });
  static const char message[] = "expected 64 lowercase hexadecimal HASH_V0 digits";
  jq_value error = jq_text((const uint8_t *)message, sizeof(message) - 1);
  return jq_con(rt->ci_err, (jq_value[]){ error });
}

jq_value jq_i_hash_to_text(jq_rt *rt, const jq_value *a) {
  (void)rt;
  if (!jq_is_hash(a[0])) type_err_args("hash.to-text", a, 1);
  static const char digits[] = "0123456789abcdef";
  const uint8_t *bytes = jq_hash_bytes(a[0]);
  uint8_t spelling[64];
  for (uint64_t i = 0; i < 32; i++) {
    spelling[2 * i] = (uint8_t)digits[bytes[i] >> 4];
    spelling[2 * i + 1] = (uint8_t)digits[bytes[i] & 15];
  }
  jq_drop(a[0]);
  return jq_text(spelling, 64);
}

jq_value jq_i_code_to_int(jq_rt *rt, const jq_value *a) {
  if (!jq_is_code(a[0])) type_err_args("code.to-int", a, 1);
  jq_value f = a[0];
  jq_value head = jq_code_head(f);
  jq_value r;
  if (jq_text_len(head) == 3 && memcmp(jq_text_bytes(head), "lit", 3) == 0 &&
      jq_code_argc(f) == 1 && jq_code_kind(f, 0) == JQ_CA_INT)
    r = vsome(rt, jq_code_datum(f, 0));
  else
    r = rt->v_none;
  jq_drop(a[0]);
  return r;
}

jq_value jq_i_code_to_text(jq_rt *rt, const jq_value *a) {
  if (!jq_is_code(a[0])) type_err_args("code.to-text", a, 1);
  jq_value f = a[0];
  jq_value head = jq_code_head(f);
  jq_value r;
  if (jq_text_len(head) == 3 && memcmp(jq_text_bytes(head), "lit", 3) == 0 &&
      jq_code_argc(f) == 1 && jq_code_kind(f, 0) == JQ_CA_TEXT) {
    jq_value t = jq_code_datum(f, 0);
    jq_dup(t);
    r = vsome(rt, t);
  } else
    r = rt->v_none;
  jq_drop(a[0]);
  return r;
}

/* Reader.valid_head, over text bytes */
static bool code_head_ok(const uint8_t *s, uint64_t n) {
  if (n == 0 || s[0] < 'a' || s[0] > 'z') return false;
  for (uint64_t i = 0; i < n; i++) {
    uint8_t c = s[i];
    if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')) return false;
  }
  return true;
}

/* OCaml %S: quoted, with String.escaped's exact classes — backslash and
   quote escaped, \n \t \r \b named, decimal \DDD for other bytes
   outside 0x20..0x7e. Heads are arbitrary runtime texts, so the buffer
   grows (a fixed one truncated long heads; task 73 review). Caller
   frees. */
static char *ocaml_escaped(const uint8_t *s, uint64_t n) {
  size_t cap = (size_t)n * 4 + 3;
  char *out = malloc(cap);
  if (!out) jq_runtime_error("jacquard runtime: out of memory");
  size_t w = 0;
  out[w++] = '"';
  for (uint64_t i = 0; i < n; i++) {
    uint8_t c = s[i];
    switch (c) {
    case '"':
    case '\\':
      out[w++] = '\\';
      out[w++] = (char)c;
      break;
    case '\n':
      out[w++] = '\\';
      out[w++] = 'n';
      break;
    case '\t':
      out[w++] = '\\';
      out[w++] = 't';
      break;
    case '\r':
      out[w++] = '\\';
      out[w++] = 'r';
      break;
    case '\b':
      out[w++] = '\\';
      out[w++] = 'b';
      break;
    default:
      if (c < 0x20 || c >= 0x7f) w += (size_t)snprintf(out + w, 5, "\\%03u", c);
      else out[w++] = (char)c;
    }
  }
  out[w++] = '"';
  out[w] = 0;
  return out;
}

jq_value jq_i_code_form(jq_rt *rt, const jq_value *a) {
  (void)rt;
  if (!is_text(a[0])) type_err_args("code.form", a, 2);
  const uint8_t *hs = jq_text_bytes(a[0]);
  uint64_t hn = jq_text_len(a[0]);
  if (!code_head_ok(hs, hn)) {
    char *esc = ocaml_escaped(hs, hn);
    fprintf(stderr, "type error: code.form: %s is not a valid form head\n", esc);
    exit(2);
  }
  /* walk the cons list twice: count, then fill (the interpreter errors on
     the first non-conforming node with its show) */
  uint64_t count = 0;
  jq_value it = a[1];
  bool bad = false;
  for (;;) {
    if (is_con_named(it, "cons") && jq_con_arity(it) == 2) {
      jq_value hd = jq_con_fields(it)[0];
      if (!jq_is_code(hd)) {
        bad = true;
        break;
      }
      count++;
      it = jq_con_fields(it)[1];
    } else if (is_con_named(it, "nil") && jq_con_arity(it) == 0)
      break;
    else {
      bad = true;
      break;
    }
  }
  if (bad) {
    char *shown = jq_show(it);
    fprintf(stderr, "type error: code.form expects a list of code, got %s\n", shown);
    exit(2);
  }
  if (count > (UINT16_MAX - 1) / 2)
    jq_runtime_error("jacquard runtime: form arity exceeds the 32767 limit");
  jq_value node = jq_code_node(a[0], (uint16_t)count);
  it = a[1];
  for (uint64_t i = 0; i < count; i++) {
    jq_value hd = jq_con_fields(it)[0];
    jq_dup(hd);
    jq_code_set(node, (uint16_t)i, JQ_CA_FORM, hd);
    it = jq_con_fields(it)[1];
  }
  jq_drop(a[1]); /* the head text's ownership moved into the node */
  return node;
}

jq_value jq_i_code_un_form(jq_rt *rt, const jq_value *a) {
  if (!jq_is_code(a[0])) type_err_args("code.un-form", a, 1);
  jq_value f = a[0];
  uint16_t n = jq_code_argc(f);
  for (uint16_t i = 0; i < n; i++)
    if (jq_code_kind(f, i) != JQ_CA_FORM) {
      jq_drop(a[0]);
      return rt->v_none;
    }
  jq_value list = rt->v_nil;
  for (uint16_t i = n; i > 0; i--) {
    jq_value sub = jq_code_datum(f, i - 1);
    jq_dup(sub);
    list = jq_con(rt->ci_cons, (jq_value[]){ sub, list });
  }
  jq_value head = jq_code_head(f);
  jq_dup(head);
  jq_value r = vsome(rt, jq_tuple(2, (jq_value[]){ head, list }));
  jq_drop(a[0]);
  return r;
}

jq_value jq_i_code_eq_q(jq_rt *rt, const jq_value *a) {
  if (!jq_is_code(a[0]) || !jq_is_code(a[1])) type_err_args("code.eq?", a, 2);
  bool r = jq_code_eq(a[0], a[1]);
  jq_drop(a[0]);
  jq_drop(a[1]);
  return vbool(rt, r);
}

jq_value jq_i_code_diff(jq_rt *rt, const jq_value *a) {
  (void)rt;
  if (!jq_is_code(a[0]) || !jq_is_code(a[1])) type_err_args("code.diff", a, 2);
  char *txt = jq_code_diff_render(a[0], a[1]);
  jq_value r = jq_text((const uint8_t *)txt, strlen(txt));
  free(txt);
  jq_drop(a[0]);
  jq_drop(a[1]);
  return r;
}

jq_value jq_i_code_render(jq_rt *rt, const jq_value *a) {
  (void)rt;
  if (!jq_is_code(a[0])) type_err_args("code.render", a, 1);
  char *txt = jq_code_inline(a[0]);
  jq_value rendered = jq_text((const uint8_t *)txt, strlen(txt));
  free(txt);
  jq_drop(a[0]);
  return rendered;
}

jq_value jq_i_support(jq_rt *rt, const jq_value *a) {
  if (!jq_is_ptr(a[0]) || jq_block_of(a[0])->tag != JQ_CON) {
    char *s = jq_show(a[0]);
    fprintf(stderr, "type error: %s is not a distribution value\n", s);
    exit(2);
  }
  check_dist(a[0]);
  jq_value r = support_of(rt, a[0]);
  jq_drop(a[0]);
  return r;
}

/* pmf: mass of v under d; 0.0 off-support. Value equality is show-based,
 * exactly the interpreter's rendering comparison. */
jq_value jq_i_pmf(jq_rt *rt, const jq_value *a) {
  jq_value d = a[0], v = a[1];
  if (!jq_is_ptr(d) || jq_block_of(d)->tag != JQ_CON) {
    char *s = jq_show(d);
    fprintf(stderr, "type error: %s is not a distribution value\n", s);
    exit(2);
  }
  check_dist(d);
  double mass;
  if (is_con_named(d, "uniform-int")) {
    int64_t lo = jq_int_val(jq_con_fields(d)[0]);
    int64_t hi = jq_int_val(jq_con_fields(d)[1]);
    double n = (double)(hi - lo + 1);
    mass = (jq_is_int(v) && jq_int_val(v) >= lo && jq_int_val(v) <= hi) ? 1.0 / n : 0.0;
  } else {
    jq_value entries = support_of(rt, d);
    char *vs = jq_show(v);
    mass = 0.0;
    for (jq_value it = entries; is_con_named(it, "cons"); it = jq_con_fields(it)[1]) {
      jq_value head = jq_con_fields(it)[0];
      char *xs = jq_show(jq_con_fields(head)[0]);
      if (strcmp(xs, vs) == 0) mass += jq_real_val(jq_con_fields(head)[1]);
      free(xs);
    }
    free(vs);
    jq_drop(entries);
  }
  jq_drop(d);
  jq_drop(v);
  return jq_real(mass);
}

/* --- dist.sample-lw (task 72): the likelihood-weighting driver ---
 *
 * Ported from Infer_dist.likelihood_weighting: a splitmix64 master seeded
 * by the argument; per run, one jq_rng_split child; per sample, one
 * jq_rng_float draw (inverse CDF over the unnormalized support; uniform-int
 * draws directly); observe multiplies the run's weight by the pmf and
 * resumes unit. Runs are merged on jq_show keys, normalized by the grand
 * total, and sorted (probability descending, rendering ascending). The
 * model runs against an EMPTY handler stack (the interpreter drives a
 * fresh state machine), so outer in-language handlers never see its ops;
 * grants still apply, and a root-reaching op renders with the
 * "(not handled during inference)" pseudo-effect. */

static double pmf_mass(jq_rt *rt, jq_value d, jq_value v) {
  if (is_con_named(d, "uniform-int")) {
    int64_t lo = jq_int_val(jq_con_fields(d)[0]);
    int64_t hi = jq_int_val(jq_con_fields(d)[1]);
    double n = (double)(hi - lo + 1);
    return (jq_is_int(v) && jq_int_val(v) >= lo && jq_int_val(v) <= hi) ? 1.0 / n : 0.0;
  }
  jq_value entries = support_of(rt, d);
  char *vs = jq_show(v);
  double mass = 0.0;
  for (jq_value it = entries; is_con_named(it, "cons"); it = jq_con_fields(it)[1]) {
    jq_value head = jq_con_fields(it)[0];
    char *xs = jq_show(jq_con_fields(head)[0]);
    if (strcmp(xs, vs) == 0) mass += jq_real_val(jq_con_fields(head)[1]);
    free(xs);
  }
  free(vs);
  jq_drop(entries);
  return mass;
}

/* one draw from a validated dist: exactly one jq_rng_float */
static jq_value draw_dist(jq_rt *rt, int64_t *rng, jq_value d) {
  if (is_con_named(d, "uniform-int")) {
    int64_t lo = jq_int_val(jq_con_fields(d)[0]);
    int64_t hi = jq_int_val(jq_con_fields(d)[1]);
    int64_t n = hi - lo + 1;
    return jq_int(lo + (int64_t)(jq_rng_float(rng) * (double)n));
  }
  jq_value entries = support_of(rt, d);
  double total = 0.0;
  for (jq_value it = entries; is_con_named(it, "cons"); it = jq_con_fields(it)[1])
    total += jq_real_val(jq_con_fields(jq_con_fields(it)[0])[1]);
  double u = jq_rng_float(rng) * (total > 0.0 ? total : 1.0);
  jq_value picked = 0;
  double acc = 0.0;
  for (jq_value it = entries; is_con_named(it, "cons"); it = jq_con_fields(it)[1]) {
    jq_value head = jq_con_fields(it)[0];
    double p = jq_real_val(jq_con_fields(head)[1]);
    if (u < acc + p) {
      picked = jq_con_fields(head)[0];
      break;
    }
    acc += p;
    /* interpreter fallback: past the end, the LAST entry's value */
    if (!is_con_named(jq_con_fields(it)[1], "cons")) picked = jq_con_fields(head)[0];
  }
  if (picked == 0) picked = JQ_UNIT; /* empty support: Value.unit_v */
  jq_dup(picked);
  jq_drop(entries);
  return picked;
}

typedef struct lw_state {
  int64_t rng;
  double weight;
} lw_state;

/* jq_perform's root interception during a weighted run (after grants —
   the interpreter's run_until_op captures ops only at the true root) */
jq_value jq_lw_sample(jq_rt *rt, jq_value dv) {
  lw_state *st = (lw_state *)rt->lw;
  if (!jq_is_ptr(dv) || jq_block_of(dv)->tag != JQ_CON) {
    char *s = jq_show(dv);
    fprintf(stderr, "type error: %s is not a distribution value\n", s);
    exit(2);
  }
  check_dist(dv);
  jq_value x = draw_dist(rt, &st->rng, dv);
  jq_drop(dv);
  return x; /* the resume: sample is ancestral, one value per op */
}

jq_value jq_lw_observe(jq_rt *rt, jq_value dv, jq_value v) {
  lw_state *st = (lw_state *)rt->lw;
  if (!jq_is_ptr(dv) || jq_block_of(dv)->tag != JQ_CON) {
    char *s = jq_show(dv);
    fprintf(stderr, "type error: %s is not a distribution value\n", s);
    exit(2);
  }
  check_dist(dv);
  st->weight *= pmf_mass(rt, dv, v);
  jq_drop(dv);
  jq_drop(v);
  return JQ_UNIT;
}

typedef struct lw_run {
  jq_value value;
  double weight;
  char *key; /* jq_show rendering, the merge key */
} lw_run;

static int lw_entry_cmp(const void *pa, const void *pb) {
  const lw_run *a = pa, *b = pb;
  /* probability descending, then rendering ascending (OCaml compare);
     spelled as two strict comparisons so an exotic weight (NaN cannot
     arise from normalized finite masses, but qsort demands a total order)
     falls through to the string key instead of breaking the ordering */
  if (a->weight > b->weight) return -1;
  if (a->weight < b->weight) return 1;
  return strcmp(a->key, b->key);
}

jq_value jq_i_dist_sample_lw(jq_rt *rt, const jq_value *a) {
  jq_value thunk = a[0];
  if (!jq_is_int(a[1]) || !jq_is_int(a[2])) {
    char *s0 = jq_show(a[0]);
    char *s1 = jq_show(a[1]);
    char *s2 = jq_show(a[2]);
    fprintf(stderr, "type error: dist.sample-lw expects a thunk and two ints, got %s, %s, %s\n",
            s0, s1, s2);
    exit(2);
  }
  int64_t samples = jq_int_val(a[1]);
  int64_t master = jq_int_val(a[2]);
  if (samples <= 0)
    jq_runtime_error("arithmetic error: dist.sample-lw needs a positive sample count");
  lw_state st = { 0, 1.0 };
  lw_run *runs = malloc((size_t)samples * sizeof(lw_run));
  if (!runs) jq_runtime_error("jacquard runtime: out of memory");
  /* each run is the interpreter's fresh state machine: outer in-language
     handlers are hidden behind the search floor (their entries untouched),
     grants still apply, sample/observe intercept at the root through
     rt->lw, and anything else root-reaching renders with the pseudo-effect.
     Saving the previous floor/lw makes nested drivers compose. */
  uint32_t saved_floor = rt->hs_floor;
  void *saved_lw = rt->lw;
  const char *saved_override = rt->unhandled_effect_override;
  for (int64_t i = 0; i < samples; i++) {
    st.rng = jq_rng_split(&master);
    st.weight = 1.0;
    rt->hs_floor = rt->hs_len;
    rt->lw = &st;
    rt->unhandled_effect_override = "(not handled during inference)";
    jq_dup(thunk);
    rt->apply_n = 0;
    jq_value v = jq_tc_drive(
        rt, jq_apply(rt, thunk, JQ_UNIT, JQ_UNIT, JQ_UNIT, JQ_UNIT, JQ_UNIT, JQ_UNIT,
                     JQ_UNIT, JQ_UNIT));
    rt->hs_floor = saved_floor;
    rt->lw = saved_lw;
    rt->unhandled_effect_override = saved_override;
    runs[i].value = v;
    runs[i].weight = st.weight;
    runs[i].key = jq_show(v);
  }
  /* the interpreter cons-prepends runs and folds the resulting list, so its
     float additions run in REVERSE chronological order — sum the same way
     (addition is not associative; a forward sum diverged by one ULP on
     soft-likelihood weights, sign-off find) */
  double total = 0.0;
  for (int64_t i = samples - 1; i >= 0; i--) total += runs[i].weight;
  if (total <= 0.0) {
    fputs("arithmetic error: error[E0901]: the posterior is empty: every run is "
          "impossible under the observations\n",
          stderr);
    exit(2);
  }
  /* merge on the rendering key, accumulating per key in the same reverse
     order */
  lw_run *entries = malloc((size_t)samples * sizeof(lw_run));
  if (!entries) jq_runtime_error("jacquard runtime: out of memory");
  int64_t n_entries = 0;
  for (int64_t i = samples - 1; i >= 0; i--) {
    int64_t j = 0;
    while (j < n_entries && strcmp(entries[j].key, runs[i].key) != 0) j++;
    if (j == n_entries) {
      entries[n_entries] = runs[i];
      n_entries++;
    } else {
      entries[j].weight += runs[i].weight;
      jq_drop(runs[i].value);
      free(runs[i].key);
    }
  }
  for (int64_t i = 0; i < n_entries; i++) entries[i].weight /= total;
  qsort(entries, (size_t)n_entries, sizeof(lw_run), lw_entry_cmp);
  jq_value list = rt->v_nil;
  for (int64_t i = n_entries - 1; i >= 0; i--) {
    jq_value pr = jq_con(rt->ci_pair,
                         (jq_value[]){ entries[i].value, jq_real(entries[i].weight) });
    list = jq_con(rt->ci_cons, (jq_value[]){ pr, list });
    free(entries[i].key);
  }
  free(entries);
  free(runs);
  jq_drop(thunk);
  return list;
}

/* the root sampler's draw (jq_g_dist_sample's core): validates, then one
 * draw from rt->dist_rng — the grant's single seeded stream */
jq_value jq_g_dist_draw(jq_rt *rt, jq_value d) {
  check_dist(d);
  jq_value x = draw_dist(rt, &rt->dist_rng, d);
  jq_drop(d);
  return x;
}
