#!/bin/sh
# Print the source checkout's live test inventory, computed the same way the
# release-law test computes it: compiled Alcotest/QCheck cases from the test
# binary's own listing, and cram transcript files under test/. Unreleased
# documents do not record these counts; each release freezes them at its tag
# (docs/ci-cd.md, Release Procedure).
#
# usage: inventory.sh    (after dune build @all, or at least test/test_jacquard.exe)
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$root"
exe=_build/default/test/test_jacquard.exe
if [ ! -x "$exe" ]; then
  echo "build the test binary first: opam exec -- dune build test/test_jacquard.exe" >&2
  exit 1
fi

# The binary resolves ../prelude from its working directory, so it lists its
# cases from the source test directory.
listing=$(cd test && "../$exe" list --color=never) || {
  echo "the compiled test listing failed" >&2
  exit 1
}
tests=$(printf '%s\n' "$listing" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' |
  grep -v -e '^$' -e 'qcheck random seed:' | wc -l | tr -d ' ')
crams=$(find test -type f -name '*.t' | wc -l | tr -d ' ')

echo "Alcotest/QCheck cases: $tests"
echo "Cram transcript files: $crams"
