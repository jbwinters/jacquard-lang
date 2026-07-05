#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"

# The language was renamed Weft -> Jacquard after 0.1. This script reproduces
# the FROZEN 0.1 evidence: it checks out the pre-rename lineage, so everything
# below the checkout (WEFT_PRELUDE, demos/*.sh, test/test_weft.exe) deliberately
# uses the old names. Inputs accept both spellings; new callers should pass
# JACQUARD_RELEASE_*.
REF=${JACQUARD_RELEASE_REF:-${WEFT_RELEASE_REF:-release/0.1-evidence}}
BASE=${JACQUARD_RELEASE_BASE:-${WEFT_RELEASE_BASE:-aec2c63}}
OUT=${JACQUARD_RELEASE_OUT:-${WEFT_RELEASE_OUT:-logs/release/0.1}}
TRANSCRIPTS="$OUT/transcripts"

mkdir -p "$TRANSCRIPTS"

capture() {
  name=$1
  shift
  file="$TRANSCRIPTS/$name.txt"
  echo "== $name =="
  if "$@" >"$file" 2>&1; then
    cat "$file"
  else
    cat "$file"
    echo "command failed while writing $file" >&2
    exit 1
  fi
}

echo "== release ref =="
git checkout "$REF"
git merge-base --is-ancestor "$BASE" HEAD
git rev-parse --short HEAD | tee "$OUT/commit.txt"

capture deps opam install --deps-only . --with-test --with-dev-setup --with-doc -y

capture build opam exec -- dune build @all

capture runtest opam exec -- dune runtest

capture fmt opam exec -- dune fmt

capture version _build/default/bin/main.exe --version

capture m1 env WEFT_PRELUDE="$ROOT/prelude" opam exec -- sh demos/m1.sh
capture m3 env WEFT_PRELUDE="$ROOT/prelude" opam exec -- sh demos/m3.sh
capture clarifying-question env WEFT_PRELUDE="$ROOT/prelude" opam exec -- sh demos/clarifying-question.sh
capture agent-dream env WEFT_PRELUDE="$ROOT/prelude" opam exec -- sh demos/agent-dream.sh
capture ambiguity-pipeline env WEFT_PRELUDE="$ROOT/prelude" opam exec -- sh demos/ambiguity-pipeline.sh
capture demo-warp-tests env WEFT_PRELUDE="$ROOT/prelude" opam exec -- sh demos/showcase-warp-tests.sh
capture hostile-manifest env WEFT_PRELUDE="$ROOT/prelude" opam exec -- sh demos/m4-hostile.sh

capture cli-and-gauntlet opam exec -- dune runtest \
  test/cli/demos.t \
  test/cli/diff.t \
  test/cli/dist.t \
  test/cli/escrow.t \
  test/cli/hostile-demo.t \
  test/cli/infer.t \
  test/cli/tools.t \
  test/cli/tutorial.t \
  test/cli/warp.t \
  test/cli/world.t \
  test/gauntlet

capture gauntlet-build opam exec -- dune build test/test_weft.exe
capture gauntlet-alcotest sh -c \
  'cd _build/default/test && ./test_weft.exe test '"'"'gauntlet-.*'"'"' --compact --color=never'

echo "release reproduction complete: $OUT"
