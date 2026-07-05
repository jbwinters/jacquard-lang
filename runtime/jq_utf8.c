/* UTF-8 codepoint semantics (task 66): a port of Prelude.utf8_boundaries
 * (src/prelude.ml, D9 decision). The well-formedness table makes overlongs
 * (E0 80-9F, F0 80-8F), surrogates (ED A0-BF), and beyond-U+10FFFF
 * (F4 90-BF) malformed, counted one codepoint PER BYTE, same as truncated
 * sequences. Parity pinned by corpus/golden/native/utf8.golden. */

#include "jq_value.h"

static int byte_at(const uint8_t *s, uint64_t n, uint64_t j) {
  return j < n ? s[j] : -1;
}

static bool cont(const uint8_t *s, uint64_t n, uint64_t j) {
  return (byte_at(s, n, j) & 0xC0) == 0x80;
}

static bool second_ok(int b0, int b1) {
  switch (b0) {
  case 0xE0: return b1 >= 0xA0 && b1 <= 0xBF;
  case 0xED: return b1 >= 0x80 && b1 <= 0x9F;
  case 0xF0: return b1 >= 0x90 && b1 <= 0xBF;
  case 0xF4: return b1 >= 0x80 && b1 <= 0x8F;
  default: return (b1 & 0xC0) == 0x80;
  }
}

/* Byte width of the codepoint starting at i (1 for a malformed byte). */
uint64_t jq_utf8_width(const uint8_t *s, uint64_t n, uint64_t i) {
  int b0 = s[i];
  if (b0 < 0x80) return 1;
  if ((b0 & 0xE0) == 0xC0 && b0 >= 0xC2 && cont(s, n, i + 1)) return 2;
  if ((b0 & 0xF0) == 0xE0 && second_ok(b0, byte_at(s, n, i + 1)) &&
      cont(s, n, i + 2))
    return 3;
  if ((b0 & 0xF8) == 0xF0 && b0 <= 0xF4 && second_ok(b0, byte_at(s, n, i + 1)) &&
      cont(s, n, i + 2) && cont(s, n, i + 3))
    return 4;
  return 1; /* malformed byte */
}

uint64_t jq_utf8_count(const uint8_t *s, uint64_t n) {
  uint64_t count = 0;
  for (uint64_t i = 0; i < n; i += jq_utf8_width(s, n, i)) count++;
  return count;
}
