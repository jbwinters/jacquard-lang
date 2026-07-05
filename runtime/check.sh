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

SRC="$here/jq_alloc.c $here/jq_rc.c $here/jq_text.c $here/jq_error.c $here/test/test_runtime.c"

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

# 3. fatal paths: interpreter-pinned messages, exit 2 (goldens 2026-07-05)
expect_fatal() {
  mode=$1; want=$2
  msg=$("$OUT/test_asan" "$mode" 2>&1) && { echo "FAIL: $mode exited 0"; exit 1; }
  code=$?
  [ "$code" = 2 ] || { echo "FAIL: $mode exit $code, want 2"; exit 1; }
  [ "$msg" = "$want" ] || { echo "FAIL: $mode said '$msg', want '$want'"; exit 1; }
  echo "ok fatal $mode"
}
expect_fatal div0 "arithmetic error: division by zero"
expect_fatal mod0 "arithmetic error: modulo by zero"
expect_fatal arity-overflow "jacquard runtime: constructor arity exceeds the 65535 limit"

echo "runtime check: PASS"
