/* Seeded RNG (task 66): a bit-for-bit port of Infer_dist.Rng
 * (src/infer_dist.ml) — SplitMix64 with the reference constants. LW seeds,
 * posterior tables, and fault.random streams reproduce only if every output
 * matches; parity pinned by corpus/golden/native/rng.golden.
 *
 * jq_rng_split mirrors OCaml's Int64.to_int (drops the top bit, sign-extends
 * to 63) followed by Int64.of_int. */

#include "jq_value.h"

int64_t jq_rng_next(int64_t *state) {
  *state = (int64_t)((uint64_t)*state + 0x9E3779B97F4A7C15ULL);
  uint64_t z = (uint64_t)*state;
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
  return (int64_t)(z ^ (z >> 31));
}

/* uniform in [0,1) from the top 53 bits */
double jq_rng_float(int64_t *state) {
  uint64_t bits = (uint64_t)jq_rng_next(state) >> 11;
  return (double)bits / 9007199254740992.0;
}

int64_t jq_rng_split(int64_t *state) {
  int64_t s = jq_rng_next(state);
  /* Int64.to_int keeps the low 63 bits and sign-extends */
  return (int64_t)((uint64_t)s << 1) >> 1;
}
