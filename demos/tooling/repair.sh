#!/bin/sh
# Program repair as Bayesian inference: a bug report is an observation, the
# posterior over single-edit patches is the diagnosis, and the MAP patch is a
# reviewable one-line divergence.
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
JACQUARD_DEMO_ROOT=$(CDPATH= cd -- "$here/.." && pwd)
. "$JACQUARD_DEMO_ROOT/lib/demo-env.sh"
tmp="$(mktemp "$TMPDIR/jacquard-repair-tests.XXXXXX.jqd")"
trap 'rm -f "$tmp"' EXIT

echo "== the rows announce the authority: mutation is pure, running candidates is eval =="
jacquard_demo check "$here/repair.jac" --print-sigs

echo "== without the grant the pure prefix runs; the first posterior refuses =="
jacquard_demo run "$here/repair.jac" 2>&1
echo "exit code: $?"

echo "== the granted run: mutant count, posteriors, and the MAP patch =="
jacquard_demo run "$here/repair.jac" --allow eval

echo "== Warp tests over the pure machinery =="
# Warp's test-file route remains a bootstrap-format fixture and proves that
# the kernel carrier stays runnable alongside the public surface program.
awk '/^; --- demo driver ---$/ { exit } { print }' "$here/repair.jqd" > "$tmp"
printf '\n' >> "$tmp"
cat "$here/repair-warp-tests.jqd" >> "$tmp"
jacquard_demo test "$tmp" --seed 7 --no-cache
