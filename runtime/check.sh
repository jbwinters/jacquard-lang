#!/bin/sh
# Runtime test gate (task 65 DoD): the sanitized build proves memory
# correctness; the plain build proves the deep drop runs in bounded C stack.
# Run from anywhere; artifacts go to a scratch dir ($OUT overrides; the
# default is a self-cleaning mktemp dir).
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT=${OUT:-$(mktemp -d "${TMPDIR:-/tmp}/jqrt-check-XXXXXX")}
CC=${CC:-cc}
trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT"

SRC="$here/jq_alloc.c $here/jq_rc.c $here/jq_text.c $here/jq_error.c $here/jq_show.c $here/jq_utf8.c $here/jq_rng.c $here/jq_apply.c $here/jq_intrinsics.c $here/jq_effects.c $here/jq_frames.c $here/jq_grants.c $here/test/test_runtime.c"

# 1. address+UB sanitized, 1M-node deep case (sanitizers make 10M slow)
$CC -std=c11 -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all \
    -Wall -Wextra -Werror -o "$OUT/test_asan" $SRC
ASAN_OPTIONS=detect_leaks=1 "$OUT/test_asan" 1000000

# 2. plain -O2, 10M nodes under a 1MB stack: the worklist proof
$CC -std=c11 -O2 -Wall -Wextra -Werror -o "$OUT/test_plain" $SRC
(
  ulimit -s 1024
  "$OUT/test_plain" 10000000
)

# 3. fatal paths: interpreter-pinned messages and exit codes (goldens
#    2026-07-05; runtime errors exit 2, unhandled effects exit 3)
expect_fatal() {
  mode=$1; want_code=$2; want=$3
  msg=$("$OUT/test_asan" "$mode" 2>&1) && { echo "FAIL: $mode exited 0"; exit 1; }
  code=$?
  [ "$code" = "$want_code" ] || { echo "FAIL: $mode exit $code, want $want_code"; exit 1; }
  [ "$msg" = "$want" ] || { echo "FAIL: $mode said '$msg', want '$want'"; exit 1; }
  echo "ok fatal $mode"
}
expect_fatal div0 2 "arithmetic error: division by zero"
expect_fatal mod0 2 "arithmetic error: modulo by zero"
expect_fatal arity-overflow 2 "jacquard runtime: constructor arity exceeds the 65535 limit"
expect_fatal unhandled-op 3 'unhandled effect console: operation `print` reached the root without a handler'

# 4. parity kit (task 66): the C ports must reproduce the OCaml goldens
#    byte-for-byte. Goldens regenerate via `dune exec test/gen_native_parity.exe`.
GOLD=${GOLD:-"$here/../corpus/golden/native"}
$CC -std=c11 -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all \
    -Wall -Wextra -Werror -o "$OUT/test_parity" \
    "$here/jq_alloc.c" "$here/jq_rc.c" "$here/jq_text.c" "$here/jq_error.c" \
    "$here/jq_show.c" "$here/jq_utf8.c" "$here/jq_rng.c" \
    "$here/test/test_parity.c"
for mode in show rng utf8; do
  ASAN_OPTIONS=detect_leaks=1 "$OUT/test_parity" "$mode" > "$OUT/$mode.out"
  diff -u "$GOLD/$mode.golden" "$OUT/$mode.out" || {
    echo "FAIL: $mode parity diverged"; exit 1; }
  echo "ok parity $mode"
done

echo "runtime check: PASS"
