/* Root grant natives (task 70): the --allow implementations, ported from
 * Prelude's installers (src/prelude.ml) with exact behaviors and error
 * texts. Every native consumes its arguments and returns an owned value;
 * argument validation renders like Runtime_err.Type_error, exit 2. */

#define _POSIX_C_SOURCE 200809L /* getline, clock_nanosleep */

#include "jq_value.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>

static void type_err1(const char *msg_prefix, uint16_t got_n, const jq_value *args, uint16_t n)
    __attribute__((noreturn));
static void type_err1(const char *msg_prefix, uint16_t got_n, const jq_value *args, uint16_t n) {
  (void)got_n;
  fprintf(stderr, "type error: %s", msg_prefix);
  for (uint16_t i = 0; i < n; i++) {
    char *s = jq_show(args[i]);
    fprintf(stderr, "%s%s", i ? ", " : "", s);
  }
  fputc('\n', stderr);
  exit(2);
}

static bool is_text(jq_value v) {
  return jq_is_ptr(v) && jq_block_of(v)->tag == JQ_TEXT;
}

/* console: print writes the text through stdout and resumes with unit */
jq_value jq_g_print(jq_rt *rt, const jq_value *args) {
  (void)rt;
  if (!is_text(args[0])) type_err1("print expects one text, got ", 1, args, 1);
  fwrite(jq_text_bytes(args[0]), 1, jq_text_len(args[0]), stdout);
  jq_drop(args[0]);
  return JQ_UNIT;
}

/* console: read-line resumes with one stdin line, EOF reads as "" */
jq_value jq_g_read_line(jq_rt *rt, const jq_value *args) {
  (void)rt;
  (void)args;
  char *line = NULL;
  size_t cap = 0;
  ssize_t got = getline(&line, &cap, stdin);
  jq_value r;
  if (got < 0) r = jq_text((const uint8_t *)"", 0);
  else {
    if (got > 0 && line[got - 1] == '\n') got--;
    r = jq_text((const uint8_t *)line, (uint64_t)got);
  }
  free(line);
  return r;
}

/* clock: now is milliseconds since the epoch; sleep blocks that long */
jq_value jq_g_now(jq_rt *rt, const jq_value *args) {
  (void)rt;
  (void)args;
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return jq_int((int64_t)tv.tv_sec * 1000 + tv.tv_usec / 1000);
}

jq_value jq_g_sleep(jq_rt *rt, const jq_value *args) {
  (void)rt;
  if (!jq_is_int(args[0])) type_err1("sleep expects milliseconds, got ", 1, args, 1);
  int64_t ms = jq_int_val(args[0]);
  if (ms > 0) {
    struct timespec ts = { ms / 1000, (ms % 1000) * 1000000L };
    nanosleep(&ts, NULL);
  }
  return JQ_UNIT;
}
