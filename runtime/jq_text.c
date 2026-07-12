/* Copyright (C) 2026 Josh Winters
 * SPDX-License-Identifier: AGPL-3.0-or-later
 * Additional permission applies; see ../RUNTIME-EXCEPTION.md. */

/* Text blocks (task 65): allocation, length, bytes. The UTF-8 semantics and
 * text operations land with the parity kit (task 66). */

#include "jq_value.h"

#include <string.h>

bool jq_text_eq(jq_value a, jq_value b) {
  uint64_t la = jq_text_len(a), lb = jq_text_len(b);
  return la == lb && memcmp(jq_text_bytes(a), jq_text_bytes(b), la) == 0;
}
