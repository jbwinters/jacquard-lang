/* Parity mirror (task 66): emits the SAME lines the OCaml golden generator
 * (test/gen_native_parity.ml) writes — keep the corpora in lockstep, in
 * order. check.sh diffs `test_parity show|rng|utf8` against
 * the corpus/golden/native goldens; a diff is a bug in the C ports. */

#include "../jq_value.h"

#include <float.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Statically initialized blocks: C11 forbids initializing a flexible array
 * member, so statics use a layout-compatible struct with a sized payload. */
#define STATIC_BLOCK(name, tag, nwords, ...)                                   \
  static struct {                                                              \
    uint32_t rc;                                                               \
    uint8_t tag_;                                                              \
    uint8_t flags;                                                             \
    uint16_t n;                                                                \
    uint64_t payload[nwords];                                                  \
  } name = { JQ_RC_STATIC, tag, 0, nwords, { __VA_ARGS__ } }

static void show_line(jq_value v) {
  char *s = jq_show(v);
  puts(s);
  free(s);
}

static void mode_show(void) {
  /* ints */
  show_line(jq_int(0));
  show_line(jq_int(1));
  show_line(jq_int(-1));
  show_line(jq_int(42));
  show_line(jq_int(4611686018427387903LL));
  show_line(jq_int(-4611686018427387904LL));
  /* reals */
  double reals[] = { 0.0,   -0.0,  1.0,       1.5,     -2.75,
                     0.1,   3.14159265358979312, 0.1 + 0.2, 123456789.123456789,
                     1e300, 1e-300, DBL_MAX,  5e-324 };
  for (size_t i = 0; i < sizeof reals / sizeof *reals; i++) {
    jq_value r = jq_real(reals[i]);
    show_line(r);
    jq_drop(r);
  }
  jq_value inf = jq_real(INFINITY);
  show_line(inf);
  jq_drop(inf);
  jq_value ninf = jq_real(-INFINITY);
  show_line(ninf);
  jq_drop(ninf);
  jq_value qnan = jq_real(NAN);
  show_line(qnan);
  jq_drop(qnan);
  /* texts (bytes must match the OCaml corpus exactly) */
  const char *texts[] = {
    "",
    "hello",
    "with \"quotes\" and \\ backslash",
    "line\nbreak\ttab\rcr",
    "ctrl \x01 and del \x7f",
    "utf-8: h\xc3\xa9llo \xe2\x86\x92 \xf0\x9f\x8e\x89",
  };
  for (size_t i = 0; i < sizeof texts / sizeof *texts; i++) {
    jq_value t = jq_text((const uint8_t *)texts[i], strlen(texts[i]));
    show_line(t);
    jq_drop(t);
  }
  /* embedded NUL: explicit length — the renderer is length-based */
  jq_value nul = jq_text((const uint8_t *)"nul\0mid", 7);
  show_line(nul);
  jq_drop(nul);
  jq_value secret =
      jq_secret((const uint8_t *)"ET4-native-parity-fixture", 25);
  show_line(secret);
  jq_drop(secret);
  /* tuples */
  show_line(JQ_UNIT);
  jq_value t1 = jq_tuple(1, (jq_value[]){ jq_int(1) });
  show_line(t1);
  jq_drop(t1);
  jq_value two = jq_text((const uint8_t *)"two", 3);
  jq_value t3 = jq_tuple(3, (jq_value[]){ jq_int(1), two, jq_real(3.0) });
  show_line(t3);
  jq_drop(t3);
  jq_value nested = jq_tuple(
      2, (jq_value[]){
             jq_tuple(2, (jq_value[]){ jq_int(1), jq_int(2) }),
             jq_tuple(2, (jq_value[]){
                             jq_int(3),
                             jq_tuple(2, (jq_value[]){ jq_int(4), jq_int(5) }),
                         }),
         });
  show_line(nested);
  jq_drop(nested);
  /* constructors applied and not */
  static const jq_con_info nil_info = { 0, 0, 0, "nil" };
  static const jq_con_info cons_info = { 0, 1, 2, "cons" };
  static const jq_con_info some_info = { 1, 0, 1, "some" };
  static const jq_con_info pair_info = { 2, 0, 2, "pair" };
  jq_value nil = jq_con(&nil_info, NULL);
  show_line(nil);
  jq_value c =
      jq_con(&cons_info, (jq_value[]){ jq_int(1), nil /* ownership moves */ });
  show_line(c);
  jq_drop(c);
  jq_value x = jq_text((const uint8_t *)"x", 1);
  jq_value s = jq_con(&some_info, (jq_value[]){ x });
  show_line(s);
  jq_drop(s);
  STATIC_BLOCK(pair_ctor, JQ_CONSTRUCTOR, 1, (uint64_t)&pair_info);
  show_line((jq_value)&pair_ctor);
  /* placeholders */
  static const uint8_t op_hash[32] = { 0 };
  static const jq_op_info print_info = { op_hash, "console", "print", 0 };
  STATIC_BLOCK(print_op, JQ_OP, 1, (uint64_t)&print_info);
  show_line((jq_value)&print_op);
  jq_value clo = jq_closure((void *)0xC0DE, 0, 0, NULL, UINT16_MAX);
  show_line(clo);
  jq_drop(clo);
  static const jq_builtin_info add_info = { 0, 2, "add", NULL };
  STATIC_BLOCK(add_builtin, JQ_BUILTIN, 1, (uint64_t)&add_info);
  show_line((jq_value)&add_builtin);
  /* zero-payload static: hand-rolled (a zero-length array cannot init) */
  static struct {
    uint32_t rc;
    uint8_t tag_;
    uint8_t flags;
    uint16_t n;
    uint64_t payload[1];
  } resume0 = { JQ_RC_STATIC, JQ_RESUME, 0, 0, { 0 } };
  show_line((jq_value)&resume0);
}

static void mode_rng(void) {
  int64_t seeds[] = { 0, 1, 42, 0x3FFFFFFF, -1, -4611686018427387904LL,
                      4611686018427387903LL };
  for (size_t i = 0; i < sizeof seeds / sizeof *seeds; i++) {
    printf("seed %lld\n", (long long)seeds[i]);
    int64_t st = seeds[i];
    for (int k = 0; k < 1000; k++)
      printf("%lld\n", (long long)jq_rng_next(&st));
    printf("floats %lld\n", (long long)seeds[i]);
    st = seeds[i];
    for (int k = 0; k < 100; k++) {
      jq_value r = jq_real(jq_rng_float(&st));
      show_line(r);
      jq_drop(r);
    }
  }
  printf("split-chain 42\n");
  int64_t st = 42;
  for (int k = 0; k < 10; k++) {
    int64_t child = jq_rng_split(&st);
    printf("%lld\n", (long long)jq_rng_next(&child));
  }
}

static int hex_val(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  return -1;
}

static void mode_utf8(void) {
  /* the hex corpus, lockstep with gen_native_parity.ml's utf8_corpus */
  const char *corpus[] = {
    "",
    "616263",
    "68c3a96c6c6f",
    "f09f8e89",
    "e28692",
    "80",
    "c3",
    "c0af",
    "e08080",
    "eda080",
    "f4908080",
    "f0908d88",
    "e0a080",
    "6180" "62" "c2a2" "63",
    "fffe",
  };
  for (size_t i = 0; i < sizeof corpus / sizeof *corpus; i++) {
    const char *hex = corpus[i];
    size_t hn = strlen(hex) / 2;
    uint8_t bytes[64];
    for (size_t j = 0; j < hn; j++)
      bytes[j] = (uint8_t)(hex_val(hex[2 * j]) * 16 + hex_val(hex[2 * j + 1]));
    printf("%s %llu\n", hex, (unsigned long long)jq_utf8_count(bytes, hn));
  }
}

int main(int argc, char **argv) {
  if (argc != 2) {
    fputs("usage: test_parity show|rng|utf8\n", stderr);
    return 1;
  }
  if (strcmp(argv[1], "show") == 0) mode_show();
  else if (strcmp(argv[1], "rng") == 0) mode_rng();
  else if (strcmp(argv[1], "utf8") == 0) mode_utf8();
  else return 1;
  return 0;
}
