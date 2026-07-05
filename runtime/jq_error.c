/* Fatal runtime errors (task 65): the interpreter's runtime-failure contract
 * is a rendered message on stderr and exit 2; emitted code and the runtime
 * both route through here. Messages are pinned against `jacquard run`. */

#include "jq_value.h"

#include <stdio.h>
#include <stdlib.h>

void jq_runtime_error(const char *msg) {
  fprintf(stderr, "%s\n", msg);
  exit(2);
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
