/* Copyright (C) 2026 Josh Winters
 * SPDX-License-Identifier: Apache-2.0
 * Additional permission applies; see ../RUNTIME-EXCEPTION.md. */

/* Fatal runtime errors (task 65): native execution renders the same canonical
 * fields and exits with the same status as Runtime_err.to_diag. */

#include "jq_value.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  const char *summary;
  const char *cause_prefix;
  const char *next_step;
  int status;
} jq_error_contract;

/* A depth (rather than a bool) makes nested likelihood-weighting drivers
 * compose. Thread-local storage keeps separate embedded program threads from
 * sharing the dynamic diagnostic context. */
static _Thread_local unsigned inference_depth;

void jq_runtime_inference_enter(void) { inference_depth++; }

void jq_runtime_inference_leave(void) {
  if (inference_depth == 0) abort();
  inference_depth--;
}

static void write_indented(const char *text) {
  for (const char *cursor = text; *cursor; cursor++) {
    fputc(*cursor, stderr);
    if (*cursor == '\n' && cursor[1] != '\0') fputs("         ", stderr);
  }
}

static const char *inference_summary = "Probabilistic inference stopped on a runtime failure.";
static const char *inference_next_step =
    "Correct the reported model runtime failure and rerun inference.";

static void inference_start(unsigned nested_wrappers) {
  fprintf(stderr, "error[E0902]: %s\n  Cause: ", inference_summary);
  for (unsigned i = 0; i < nested_wrappers; i++)
    fprintf(stderr, "E0902: %s (", inference_summary);
}

static void inference_finish(unsigned nested_wrappers) __attribute__((noreturn));
static void inference_finish(unsigned nested_wrappers) {
  for (unsigned i = 0; i < nested_wrappers; i++) fputc(')', stderr);
  fprintf(stderr, "\n  Next step: %s\n", inference_next_step);
  exit(2);
}

static void vwrite_indentedf(const char *format, va_list ap) {
  va_list measured;
  va_copy(measured, ap);
  int length = vsnprintf(NULL, 0, format, measured);
  va_end(measured);
  if (length < 0) {
    fputs("native diagnostic detail could not be formatted", stderr);
    return;
  }
  char *rendered = malloc((size_t)length + 1);
  if (!rendered) {
    fputs("native diagnostic detail could not be allocated", stderr);
    return;
  }
  vsnprintf(rendered, (size_t)length + 1, format, ap);
  write_indented(rendered);
  free(rendered);
}

static jq_error_contract contract(jq_error_kind kind) {
  switch (kind) {
  case JQ_ERROR_MATCH:
    return (jq_error_contract){"No match clause accepted the value", "no clause matched the value ",
                               "Add a clause for this value or a wildcard default.", 2};
  case JQ_ERROR_UNHANDLED:
    return (jq_error_contract){"An effect reached the root without a handler", "unhandled effect ",
                               "Grant the effect at the root or handle it inside the program.", 3};
  case JQ_ERROR_ARITY:
    return (jq_error_contract){"Runtime call arity does not agree", "arity mismatch: ",
                               "Pass exactly the number of arguments required by the callable.", 2};
  case JQ_ERROR_ARITHMETIC:
    return (jq_error_contract){"Arithmetic operation failed", "arithmetic error: ",
                               "Correct the arithmetic inputs and run the program again.", 2};
  case JQ_ERROR_IO:
    return (jq_error_contract){"World-effect I/O failed", "io error: ",
                               "Correct the path, permissions, or external resource and try again.", 2};
  case JQ_ERROR_TYPE:
    return (jq_error_contract){"Runtime value has the wrong type", "type error: ",
                               "Pass a value of the type required by this operation.", 2};
  case JQ_ERROR_UNRESOLVED:
    return (jq_error_contract){"Runtime reference is unresolved", "unresolved reference: ",
                               "Resolve every name and hash before evaluation.", 2};
  case JQ_ERROR_EVAL:
    return (jq_error_contract){"Eval rejected its code value", "eval rejected its argument: ",
                               "Pass validated closed code to eval.", 2};
  case JQ_ERROR_NATIVE:
    return (jq_error_contract){"Native runtime could not continue", "",
                               "Report this native runtime failure with the program and command.", 2};
  }
  abort();
}

void jq_diagnostic_fail(int status, const char *code, const char *summary,
                        const char *cause, const char *next_step) {
  if (inference_depth > 0) {
    unsigned nested_wrappers = inference_depth - 1;
    inference_start(nested_wrappers);
    if (code && strcmp(code, "E0901") == 0) {
      fprintf(stderr, "%s: %s (", code, summary);
      write_indented(cause);
      fputc(')', stderr);
    } else {
      write_indented(cause);
    }
    inference_finish(nested_wrappers);
  }
  if (code)
    fprintf(stderr, "error[%s]: %s\n", code, summary);
  else
    fprintf(stderr, "error: %s\n", summary);
  fputs("  Cause: ", stderr);
  write_indented(cause);
  fprintf(stderr, "\n  Next step: %s\n", next_step);
  exit(status);
}

void jq_diagnostic_failf(int status, const char *code, const char *summary,
                         const char *next_step, const char *cause_format, ...) {
  if (inference_depth > 0) {
    unsigned nested_wrappers = inference_depth - 1;
    inference_start(nested_wrappers);
    if (code && strcmp(code, "E0901") == 0) fprintf(stderr, "%s: %s (", code, summary);
    va_list inference_ap;
    va_start(inference_ap, cause_format);
    vwrite_indentedf(cause_format, inference_ap);
    va_end(inference_ap);
    if (code && strcmp(code, "E0901") == 0) fputc(')', stderr);
    inference_finish(nested_wrappers);
  }
  if (code)
    fprintf(stderr, "error[%s]: %s\n", code, summary);
  else
    fprintf(stderr, "error: %s\n", summary);
  fputs("  Cause: ", stderr);
  va_list ap;
  va_start(ap, cause_format);
  vwrite_indentedf(cause_format, ap);
  va_end(ap);
  fprintf(stderr, "\n  Next step: %s\n", next_step);
  exit(status);
}

static void start(jq_error_kind kind) {
  jq_error_contract c = contract(kind);
  if (inference_depth > 0) {
    inference_start(inference_depth - 1);
    fputs(c.cause_prefix, stderr);
  } else
    fprintf(stderr, "error: %s\n  Cause: %s", c.summary, c.cause_prefix);
}

static void finish(jq_error_kind kind) __attribute__((noreturn));
static void finish(jq_error_kind kind) {
  jq_error_contract c = contract(kind);
  if (inference_depth > 0) inference_finish(inference_depth - 1);
  fprintf(stderr, "\n  Next step: %s\n", c.next_step);
  exit(c.status);
}

void jq_runtime_fail(jq_error_kind kind, const char *detail) {
  start(kind);
  write_indented(detail);
  finish(kind);
}

void jq_runtime_vfailf(jq_error_kind kind, const char *fmt, va_list ap) {
  start(kind);
  vwrite_indentedf(fmt, ap);
  finish(kind);
}

void jq_runtime_failf(jq_error_kind kind, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  jq_runtime_vfailf(kind, fmt, ap);
}

void jq_runtime_error(const char *msg) {
  const struct {
    const char *prefix;
    jq_error_kind kind;
  } prefixes[] = {
      {"no clause matched the value ", JQ_ERROR_MATCH},
      {"unhandled effect ", JQ_ERROR_UNHANDLED},
      {"arity mismatch: ", JQ_ERROR_ARITY},
      {"arithmetic error: ", JQ_ERROR_ARITHMETIC},
      {"io error: ", JQ_ERROR_IO},
      {"type error: ", JQ_ERROR_TYPE},
      {"unresolved reference: ", JQ_ERROR_UNRESOLVED},
      {"eval rejected its argument: ", JQ_ERROR_EVAL},
  };
  if (strncmp(msg, "error[E0906]: ", 14) == 0)
    jq_diagnostic_fail(2, "E0906", "A once continuation was resumed more than once", msg + 14,
                       "Resume each captured once continuation at most once.");
  if (strncmp(msg, "error[E0904]: ", 14) == 0)
    jq_diagnostic_fail(2, "E0904", "Observation is invalid at the sampling root", msg + 14,
                       "Move the observation under an inference handler.");
  if (strncmp(msg, "arithmetic error: error[E0901]: ", 32) == 0)
    jq_diagnostic_fail(2, "E0901", "The posterior is empty.", msg + 32,
                       "Change the model or observations so at least one execution branch has nonzero weight.");
  if (strncmp(msg, "arithmetic error: error[E0902]: ", 32) == 0)
    jq_diagnostic_fail(2, "E0902", "Probabilistic inference stopped on a runtime failure.", msg + 32,
                       "Correct the reported model runtime failure and rerun inference.");
  for (size_t i = 0; i < sizeof prefixes / sizeof prefixes[0]; i++) {
    size_t n = strlen(prefixes[i].prefix);
    if (strncmp(msg, prefixes[i].prefix, n) == 0)
      jq_runtime_fail(prefixes[i].kind, msg + n);
  }
  jq_runtime_fail(JQ_ERROR_NATIVE, msg);
}

/* goldens pinned from the interpreter (jacquard run, 2026-07-05) */
jq_value jq_int_div_checked(jq_value a, jq_value b) {
  if (jq_int_val(b) == 0) jq_runtime_error("arithmetic error: division by zero");
  return jq_int_div(a, b);
}

jq_value jq_int_mod_checked(jq_value a, jq_value b) {
  if (jq_int_val(b) == 0) jq_runtime_error("arithmetic error: modulo by zero");
  return jq_int_mod(a, b);
}
