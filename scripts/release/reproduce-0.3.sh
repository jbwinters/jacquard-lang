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
# JACQUARD_RELEASE_STAGES selects one stage so Release Evidence can run the
# stages as parallel jobs; every stage first checks the candidate and builds it.
STAGES=${JACQUARD_RELEASE_STAGES:-all}
case "$STAGES" in
  all | core | gm12b | native-clang | native-gcc) ;;
  *)
    echo "JACQUARD_RELEASE_STAGES must be all, core, gm12b, native-clang or native-gcc" >&2
    exit 2
    ;;
esac
stage() {
  [ "$STAGES" = all ] || [ "$STAGES" = "$1" ]
}

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
echo "$STAGES" >"$OUT/stage.txt"

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
if stage core; then
  capture docs opam exec -- dune build --root "$ROOT" @doc
  capture runtest opam exec -- dune runtest --root "$ROOT"
  capture doctest opam exec -- dune runtest --root "$ROOT" test/docs-doctest --force
  capture parser-depth scripts/parser-depth-perf.sh
fi
if stage gm12b; then
  capture gm12b opam exec -- dune build --root "$ROOT" @test/gm12b/gm12b-evidence --force
fi

for cc in clang gcc; do
  stage "native-$cc" || continue
  capture "runtime-memory-$cc" env CC="$cc" runtime/check.sh
  capture "native-diff-$cc" env CC="$cc" JACQUARD="$ROOT/_build/default/bin/main.exe" \
    opam exec -- sh scripts/native-diff.sh
  capture "native-leak-$cc" env CC="$cc" JACQUARD="$ROOT/_build/default/bin/main.exe" \
    opam exec -- sh scripts/native-leak-check.sh
  capture "native-fuzz-$cc" env CC="$cc" \
    opam exec -- dune build --root "$ROOT" @native-fuzz --force
done

if ! stage core; then
  capture final-clean-diff git diff --exit-code HEAD
  echo "release reproduction stage $STAGES complete: $OUT"
  exit 0
fi

capture fmt opam exec -- dune fmt --root "$ROOT"
capture clean-diff git diff --exit-code HEAD
capture version sh -c 'test "$(_build/default/bin/main.exe --version)" = "0.3.0"'
capture installer-smoke scripts/release/smoke-installer.sh linux-x86_64

# The demo list is shared with the CI development gate (scripts/release/run-demos.sh).
demo_list=$(scripts/release/run-demos.sh --list)
while read -r name script <&3; do
  capture "$name" env JACQUARD_PRELUDE="$ROOT/prelude" opam exec -- sh "$script"
done 3<<DEMOS
$demo_list
DEMOS

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
