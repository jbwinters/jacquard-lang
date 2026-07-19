/* Copyright (C) 2026 Josh Winters
 * SPDX-License-Identifier: Apache-2.0
 * Additional permission applies; see ../RUNTIME-EXCEPTION.md. */

/* Root grant natives (task 70): the --allow implementations, ported from
 * Prelude's installers (src/prelude.ml) with exact behaviors and error
 * texts. Every native consumes its arguments and returns an owned value;
 * argument validation renders like Runtime_err.Type_error, exit 2. */

#define _POSIX_C_SOURCE 200809L /* getline, clock_nanosleep */

#include "jq_value.h"

#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>

static void type_err1(const char *msg_prefix, uint16_t got_n, const jq_value *args, uint16_t n)
    __attribute__((noreturn));
static void type_err1(const char *msg_prefix, uint16_t got_n, const jq_value *args, uint16_t n) {
  (void)got_n;
  char *first = n > 0 ? jq_show(args[0]) : NULL;
  char *second = n > 1 ? jq_show(args[1]) : NULL;
  if (n > 1)
    jq_runtime_failf(JQ_ERROR_TYPE, "%s%s, %s", msg_prefix, first, second);
  jq_runtime_failf(JQ_ERROR_TYPE, "%s%s", msg_prefix, first ? first : "");
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

/* fs (install_fs's SANDBOX CAVEAT holds here too: the grant is the ONLY
 * boundary — --allow fs is the whole filesystem at process privilege).
 * IO failures render like Runtime_err.Io over OCaml's Sys_error, which is
 * "<path>: <strerror>" for these calls, exit 2. */

static void io_err(const char *path) __attribute__((noreturn));
static void io_err(const char *path) {
  jq_runtime_failf(JQ_ERROR_IO, "%s: %s", path, strerror(errno));
}

/* the libc calls need a NUL-terminated copy of the path text */
static char *path_cstr(jq_value text) {
  uint64_t n = jq_text_len(text);
  char *p = malloc(n + 1);
  if (!p) jq_runtime_error("jacquard runtime: out of memory");
  memcpy(p, jq_text_bytes(text), n);
  p[n] = 0;
  return p;
}

/* fs: read resumes with the whole file as text */
jq_value jq_g_fs_read(jq_rt *rt, const jq_value *args) {
  (void)rt;
  if (!is_text(args[0])) type_err1("read expects one path, got ", 1, args, 1);
  char *path = path_cstr(args[0]);
  FILE *f = fopen(path, "rb");
  if (!f) io_err(path);
  if (fseek(f, 0, SEEK_END) != 0) io_err(path);
  long len = ftell(f);
  if (len < 0) io_err(path);
  rewind(f);
  char *buf = malloc(len > 0 ? (size_t)len : 1);
  if (!buf) jq_runtime_error("jacquard runtime: out of memory");
  if (len > 0 && fread(buf, 1, (size_t)len, f) != (size_t)len) io_err(path);
  fclose(f);
  jq_value r = jq_text((const uint8_t *)buf, (uint64_t)len);
  free(buf);
  free(path);
  jq_drop(args[0]);
  return r;
}

/* fs: write creates or truncates, resumes with unit */
jq_value jq_g_fs_write(jq_rt *rt, const jq_value *args) {
  (void)rt;
  if (!is_text(args[0]) || !is_text(args[1]))
    type_err1("write expects a path and a text, got ", 2, args, 2);
  char *path = path_cstr(args[0]);
  FILE *f = fopen(path, "wb");
  if (!f) io_err(path);
  uint64_t n = jq_text_len(args[1]);
  if (n > 0 && fwrite(jq_text_bytes(args[1]), 1, n, f) != n) io_err(path);
  if (fclose(f) != 0) io_err(path);
  free(path);
  jq_drop(args[0]);
  jq_drop(args[1]);
  return JQ_UNIT;
}

static int cmp_names(const void *a, const void *b) {
  return strcmp(*(const char *const *)a, *(const char *const *)b);
}

/* fs: list-dir resumes with the entry names (no . or ..) sorted byte-wise —
 * Sys.readdir + List.sort String.compare's order */
jq_value jq_g_fs_list_dir(jq_rt *rt, const jq_value *args) {
  if (!is_text(args[0])) type_err1("list-dir expects one path, got ", 1, args, 1);
  char *path = path_cstr(args[0]);
  DIR *d = opendir(path);
  if (!d) io_err(path);
  size_t cap = 16, count = 0;
  char **names = malloc(cap * sizeof(char *));
  if (!names) jq_runtime_error("jacquard runtime: out of memory");
  struct dirent *ent;
  while ((ent = readdir(d)) != NULL) {
    if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) continue;
    if (count == cap) {
      cap *= 2;
      names = realloc(names, cap * sizeof(char *));
      if (!names) jq_runtime_error("jacquard runtime: out of memory");
    }
    names[count] = strdup(ent->d_name);
    if (!names[count]) jq_runtime_error("jacquard runtime: out of memory");
    count++;
  }
  closedir(d);
  qsort(names, count, sizeof(char *), cmp_names);
  jq_value list = rt->v_nil;
  for (size_t k = count; k > 0; k--) {
    jq_value cell[2] = { jq_text((const uint8_t *)names[k - 1], strlen(names[k - 1])), list };
    list = jq_con(rt->ci_cons, cell);
    free(names[k - 1]);
  }
  free(names);
  free(path);
  jq_drop(args[0]);
  return list;
}

/* dist (task 72): the seeded sampling grant. sample draws one value
 * ancestrally from the --seed'd stream (one jq_rng_float per draw, no
 * split — Prelude.install_dist's single Rng); observe reaching the root
 * is a defect, the interpreter's E0904 at exit 2. The draw itself lives
 * in jq_intrinsics.c (jq_g_dist_draw) beside the dist recognizers. */

jq_value jq_g_dist_sample(jq_rt *rt, const jq_value *args) {
  extern jq_value jq_g_dist_draw(jq_rt *, jq_value); /* jq_intrinsics.c */
  if (!jq_is_ptr(args[0]) || jq_block_of(args[0])->tag != JQ_CON) {
    char *s = jq_show(args[0]);
    jq_runtime_failf(JQ_ERROR_TYPE, "%s is not a distribution value", s);
  }
  return jq_g_dist_draw(rt, args[0]);
}

jq_value jq_g_dist_observe(jq_rt *rt, const jq_value *args) {
  (void)args;
  /* run_cmd renders Observe_at_root as E0904; inside a weighted run the LW
     driver flattens it to an E0902 diagnostic first (both exit 2) */
  if (rt->lw)
    jq_diagnostic_fail(2, "E0902", "Probabilistic inference stopped on a runtime failure.",
                       "observe reached the sampling root handler; observation requires an inference driver (use jacquard infer)",
                       "Correct the reported model runtime failure and rerun inference.");
  jq_diagnostic_fail(2, "E0904", "Observation is invalid at the sampling root",
                     "observe reached the sampling root handler; observation requires an inference driver (use jacquard infer)",
                     "Move the observation under an inference handler.");
}

/* infer (task 72): the stub completion grant, ported from install_infer.
 * complete takes a mk-prompt(text, option model) and resumes with the
 * pinned stub string. The content-addressed cache (--infer-cache) stays
 * interpreter-only until task 73 lands the reader/printer port that the
 * entry format needs; generated main rejects the flag up front. */
jq_value jq_g_infer_complete(jq_rt *rt, const jq_value *args) {
  (void)rt;
  jq_value p = args[0];
  if (!jq_is_ptr(p) || jq_block_of(p)->tag != JQ_CON || jq_con_arity(p) != 2 ||
      !jq_is_ptr(jq_con_fields(p)[0]) || jq_block_of(jq_con_fields(p)[0])->tag != JQ_TEXT)
    type_err1("complete expects a prompt, got ", 1, args, 1);
  jq_value text = jq_con_fields(p)[0];
  jq_value model_opt = jq_con_fields(p)[1];
  const char *fmt_pre = "<stub completion for: ";
  size_t out_cap = jq_text_len(text) + 64;
  char *model = NULL;
  uint64_t model_len = 0;
  if (jq_is_ptr(model_opt) && jq_block_of(model_opt)->tag == JQ_CON &&
      strcmp(jq_con_info_of(model_opt)->name, "some") == 0 &&
      jq_is_ptr(jq_con_fields(model_opt)[0]) &&
      jq_block_of(jq_con_fields(model_opt)[0])->tag == JQ_TEXT) {
    jq_value m = jq_con_fields(model_opt)[0];
    model = (char *)jq_text_bytes(m);
    model_len = jq_text_len(m);
    out_cap += model_len;
  }
  char *buf = malloc(out_cap);
  if (!buf) jq_runtime_error("jacquard runtime: out of memory");
  size_t n;
  if (model)
    n = (size_t)snprintf(NULL, 0, "<stub completion from %.*s for: %.*s>", (int)model_len,
                         model, (int)jq_text_len(text), (const char *)jq_text_bytes(text));
  else
    n = (size_t)snprintf(NULL, 0, "%s%.*s>", fmt_pre, (int)jq_text_len(text),
                         (const char *)jq_text_bytes(text));
  if (n + 1 > out_cap) {
    buf = realloc(buf, n + 1);
    if (!buf) jq_runtime_error("jacquard runtime: out of memory");
  }
  if (model)
    snprintf(buf, n + 1, "<stub completion from %.*s for: %.*s>", (int)model_len, model,
             (int)jq_text_len(text), (const char *)jq_text_bytes(text));
  else
    snprintf(buf, n + 1, "%s%.*s>", fmt_pre, (int)jq_text_len(text),
             (const char *)jq_text_bytes(text));
  jq_value r = jq_text((const uint8_t *)buf, (uint64_t)n);
  free(buf);
  jq_drop(args[0]);
  return r;
}
