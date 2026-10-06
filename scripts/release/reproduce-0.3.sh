#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
: "${TMPDIR:=$ROOT/.scratch/tmp}"
export TMPDIR
mkdir -p "$TMPDIR"

REF=${JACQUARD_RELEASE_REF:-HEAD}
BASE=${JACQUARD_RELEASE_BASE:-f296ec1333072a1bdddb53f707eef836926cdb43}
OUT=${JACQUARD_RELEASE_OUT:-$ROOT/.scratch/release/0.3}
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
# Evidence describes a commit: refuse staged or unstaged changes to tracked
# files, so the build sees exactly the candidate's tracked content.
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  git status --short >&2
  echo "the checkout has uncommitted changes; reproduce from a clean checkout" >&2
  exit 1
fi
git checkout "$REF"
git merge-base --is-ancestor "$BASE" HEAD
git rev-parse HEAD | tee "$OUT/commit.txt"

capture historical-manifests scripts/release/check-historical-manifests.sh \
  --commit HEAD --require-history
capture historical-manifest-adversarial scripts/release/test-historical-manifests.sh \
  --commit HEAD
# 0.2's manifest covers its own release diff, so it is verified at its tag.
capture release-0.2-manifest env -u GITHUB_SHA -u JACQUARD_RELEASE_BASE scripts/release/check-0.2-manifest.sh \
  --commit jacquard-core-0.2.0
capture release-0.2-unchanged git diff --exit-code jacquard-core-0.2.0 HEAD -- docs/release/0.2
capture release-0.3-manifest scripts/release/check-0.3-manifest.sh --commit HEAD

capture deps opam install --deps-only . --with-test --with-dev-setup --with-doc -y
capture build opam exec -- dune build --root "$ROOT" @all
capture docs opam exec -- dune build --root "$ROOT" @doc
capture runtest opam exec -- dune runtest --root "$ROOT"
capture doctest opam exec -- dune runtest --root "$ROOT" test/docs-doctest --force
capture parser-depth scripts/parser-depth-perf.sh
capture gm12b opam exec -- dune build --root "$ROOT" @test/gm12b/gm12b-evidence --force

for cc in clang gcc; do
  capture "runtime-memory-$cc" env CC="$cc" runtime/check.sh
  capture "native-diff-$cc" env CC="$cc" JACQUARD="$ROOT/_build/default/bin/main.exe" \
    opam exec -- sh scripts/native-diff.sh
  capture "native-leak-$cc" env CC="$cc" JACQUARD="$ROOT/_build/default/bin/main.exe" \
    opam exec -- sh scripts/native-leak-check.sh
  capture "native-fuzz-$cc" env CC="$cc" \
    opam exec -- dune build --root "$ROOT" @native-fuzz --force
done

capture fmt opam exec -- dune fmt --root "$ROOT"
capture clean-diff git diff --exit-code HEAD
capture version sh -c 'test "$(_build/default/bin/main.exe --version)" = "0.3.0"'
capture installer-smoke scripts/release/smoke-installer.sh linux-x86_64

capture m1 env JACQUARD_PRELUDE="$ROOT/prelude" opam exec -- sh demos/basics/m1.sh
capture m3 env JACQUARD_PRELUDE="$ROOT/prelude" opam exec -- sh demos/inference/m3.sh
capture clarifying-question env JACQUARD_PRELUDE="$ROOT/prelude" opam exec -- sh demos/inference/clarifying-question.sh
capture agent-dream env JACQUARD_PRELUDE="$ROOT/prelude" opam exec -- sh demos/worlds/agent-dream.sh
capture ambiguity-pipeline env JACQUARD_PRELUDE="$ROOT/prelude" opam exec -- sh demos/inference/ambiguity-pipeline.sh
capture demo-warp-tests env JACQUARD_PRELUDE="$ROOT/prelude" opam exec -- sh demos/tooling/showcase-warp-tests.sh
capture repair env JACQUARD_PRELUDE="$ROOT/prelude" opam exec -- sh demos/tooling/repair.sh
capture hostile-manifest env JACQUARD_PRELUDE="$ROOT/prelude" opam exec -- sh demos/worlds/m4-hostile.sh
capture preflight env JACQUARD_PRELUDE="$ROOT/prelude" opam exec -- sh demos/worlds/preflight.sh
capture escrow env JACQUARD_PRELUDE="$ROOT/prelude" opam exec -- sh demos/worlds/escrow/run.sh
capture release-risk env JACQUARD_PRELUDE="$ROOT/prelude" opam exec -- sh demos/case-studies/release-risk/run.sh
capture stormglass env JACQUARD_PRELUDE="$ROOT/prelude" opam exec -- sh demos/case-studies/stormglass/run.sh
capture structured-concurrency env JACQUARD_PRELUDE="$ROOT/prelude" opam exec -- sh demos/concurrency/run.sh
capture governed-workspace env JACQUARD_PRELUDE="$ROOT/prelude" opam exec -- sh demos/governed-workspace/run.sh
capture night-shift env JACQUARD_PRELUDE="$ROOT/prelude" opam exec -- sh demos/case-studies/night-shift/run.sh

capture cli-and-gauntlet opam exec -- dune runtest --root "$ROOT" \
  test/cli/abstract-types-demos.t \
  test/cli/applications.t \
  test/cli/demos.t \
  test/cli/case-studies.t \
  test/cli/concurrency-evidence.t \
  test/cli/diff.t \
  test/cli/dist.t \
  test/cli/effect-payload.t \
  test/cli/escrow.t \
  test/cli/fuel.t \
  test/cli/governed-membranes-release.t \
  test/cli/governed-workspace.t \
  test/cli/hostile-demo.t \
  test/cli/host-worker.t \
  test/cli/infer.t \
  test/cli/inference-outcomes.t \
  test/cli/interface.t \
  test/cli/named-args.t \
  test/cli/onboarding.t \
  test/cli/opaque-types.t \
  test/cli/predicates.t \
  test/cli/project-bundle.t \
  test/cli/project-deps.t \
  test/cli/project-guards.t \
  test/cli/project-local.t \
  test/cli/project-manifest.t \
  test/cli/relate-policy.t \
  test/cli/relational-warp.t \
  test/cli/repair.t \
  test/cli/scoped-instances.t \
  test/cli/showcase.t \
  test/cli/surface-field-update.t \
  test/cli/surface-try.t \
  test/cli/surface.t \
  test/cli/tools.t \
  test/cli/tutorial.t \
  test/cli/warp.t \
  test/cli/world.t \
  test/gauntlet

capture gauntlet-build opam exec -- dune build --root "$ROOT" test/test_jacquard.exe
capture gauntlet-alcotest sh -c \
  'cd _build/default/test && ./test_jacquard.exe test '"'"'gauntlet-.*'"'"' --compact --color=never'

capture final-clean-diff git diff --exit-code HEAD
echo "release reproduction complete: $OUT"
