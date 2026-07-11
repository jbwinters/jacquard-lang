#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
: "${TMPDIR:=$ROOT/.scratch/tmp}"
export TMPDIR
mkdir -p "$TMPDIR"

REF=${JACQUARD_RELEASE_REF:-HEAD}
BASE=${JACQUARD_RELEASE_BASE:-738dc8e}
OUT=${JACQUARD_RELEASE_OUT:-$ROOT/.scratch/release/0.1}
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

capture runtime-memory runtime/check.sh
capture native-diff env CC=clang opam exec -- sh scripts/native-diff.sh
capture native-leak env CC=clang opam exec -- sh scripts/native-leak-check.sh
capture native-fuzz env CC=clang opam exec -- dune build @native-fuzz

capture fmt opam exec -- dune fmt

capture version _build/default/bin/main.exe --version

capture installer-smoke scripts/release/smoke-installer.sh linux-x86_64

capture m1 env JACQUARD_PRELUDE="$ROOT/prelude" opam exec -- sh demos/m1.sh
capture m3 env JACQUARD_PRELUDE="$ROOT/prelude" opam exec -- sh demos/m3.sh
capture clarifying-question env JACQUARD_PRELUDE="$ROOT/prelude" opam exec -- sh demos/clarifying-question.sh
capture agent-dream env JACQUARD_PRELUDE="$ROOT/prelude" opam exec -- sh demos/agent-dream.sh
capture ambiguity-pipeline env JACQUARD_PRELUDE="$ROOT/prelude" opam exec -- sh demos/ambiguity-pipeline.sh
capture demo-warp-tests env JACQUARD_PRELUDE="$ROOT/prelude" opam exec -- sh demos/showcase-warp-tests.sh
capture repair env JACQUARD_PRELUDE="$ROOT/prelude" opam exec -- sh demos/repair.sh
capture hostile-manifest env JACQUARD_PRELUDE="$ROOT/prelude" opam exec -- sh demos/m4-hostile.sh

capture cli-and-gauntlet opam exec -- dune runtest \
  test/cli/demos.t \
  test/cli/diff.t \
  test/cli/dist.t \
  test/cli/escrow.t \
  test/cli/hostile-demo.t \
  test/cli/infer.t \
  test/cli/repair.t \
  test/cli/showcase.t \
  test/cli/surface.t \
  test/cli/tools.t \
  test/cli/tutorial.t \
  test/cli/warp.t \
  test/cli/world.t \
  test/gauntlet

capture gauntlet-build opam exec -- dune build test/test_jacquard.exe
capture gauntlet-alcotest sh -c \
  'cd _build/default/test && ./test_jacquard.exe test '"'"'gauntlet-.*'"'"' --compact --color=never'

echo "release reproduction complete: $OUT"
