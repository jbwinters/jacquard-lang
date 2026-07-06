/* Builtin intrinsics (task 67): the native implementations of the prelude's
 * marker builtins, ported from Prelude.wire_builtins (src/prelude.ml) with
 * the interpreter's exact behaviors and error texts. Every intrinsic
 * CONSUMES its arguments (no-ops for ints/statics); type errors render like
 * Runtime_err.Type_error ("type error: <name> expects ..., got <shows>")
 * and exit 2. docs/native-intrinsics.md tracks coverage. */

#include "jq_value.h"

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
  REAL2("add-real");
  return real2(a[0], a[1], jq_real_val(a[0]) + jq_real_val(a[1]));
}
jq_value jq_i_sub_real(jq_rt *rt, const jq_value *a) {
  (void)rt;
  REAL2("sub-real");
  return real2(a[0], a[1], jq_real_val(a[0]) - jq_real_val(a[1]));
}
jq_value jq_i_mul_real(jq_rt *rt, const jq_value *a) {
  (void)rt;
  REAL2("mul-real");
  return real2(a[0], a[1], jq_real_val(a[0]) * jq_real_val(a[1]));
}
jq_value jq_i_div_real(jq_rt *rt, const jq_value *a) {
  (void)rt;
  REAL2("div-real");
  /* IEEE division: the interpreter divides OCaml floats, inf/nan included */
  return real2(a[0], a[1], jq_real_val(a[0]) / jq_real_val(a[1]));
}
jq_value jq_i_lt_real(jq_rt *rt, const jq_value *a) {
  REAL2("lt-real");
  bool r = jq_real_val(a[0]) < jq_real_val(a[1]);
  jq_drop(a[0]);
  jq_drop(a[1]);
  return vbool(rt, r);
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

jq_value jq_i_text_concat(jq_rt *rt, const jq_value *a) {
  (void)rt;
  if (!is_text(a[0]) || !is_text(a[1])) type_err2("text.concat", "texts", a[0], a[1]);
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
  }
  fputc('\n', stderr);
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
