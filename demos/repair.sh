#!/bin/sh
# Program repair as Bayesian inference: a bug report is an observation, the
# posterior over single-edit patches is the diagnosis, and the MAP patch is a
# reviewable one-line divergence. Run from the repo root:
#   sh demos/repair.sh
set -u
WEFT="${WEFT:-dune exec weft --}"
here="$(dirname "$0")"
tmp="$(mktemp "${TMPDIR:-/tmp}/weft-repair-tests.XXXXXX.wft")"
trap 'rm -f "$tmp"' EXIT

echo "== the rows announce the authority: mutation is pure, running candidates is eval =="
$WEFT check "$here/repair.wft" --print-sigs

echo "== without the grant the pure prefix runs; the first posterior refuses =="
$WEFT run "$here/repair.wft" 2>&1
echo "exit code: $?"

echo "== the granted run: mutant count, posteriors, and the MAP patch =="
$WEFT run "$here/repair.wft" --allow eval

echo "== Warp tests over the pure machinery =="
awk '/^; --- demo driver ---$/ { exit } { print }' "$here/repair.wft" > "$tmp"
printf '\n' >> "$tmp"
cat "$here/repair-warp-tests.wft" >> "$tmp"
$WEFT test "$tmp" --seed 7 --no-cache
