#!/usr/bin/env sh
set -eu

if [ "$#" -ne 4 ]; then
  echo "usage: $0 JAC LAW EXPECTED PRELUDE" >&2
  exit 2
fi

jac=$1
law=$2
expected=$3
prelude=$4

repo_root=$(git rev-parse --show-toplevel)
: "${TMPDIR:=$repo_root/.scratch/tmp}"
export TMPDIR
mkdir -p "$TMPDIR"

work=$(mktemp -d "$TMPDIR/gm12b-exhaustive.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
actual=$work/workspace-forward-laws.actual

retain_actual() {
  if [ -n "${GM12B_EVIDENCE_OUT:-}" ]; then
    mkdir -p "$(dirname -- "$GM12B_EVIDENCE_OUT")"
    cp "$actual" "$GM12B_EVIDENCE_OUT"
  fi
}

if ! JACQUARD_PRELUDE=$prelude "$jac" test "$law" \
  --exhaustive --budget 120000 --no-cache >"$actual"; then
  retain_actual
  cat "$actual" >&2
  exit 1
fi

retain_actual

if ! diff -u "$expected" "$actual"; then
  echo "GM.12B exhaustive transcript mismatch" >&2
  exit 1
fi

cat "$actual"
