# Governed Membranes Reproduction

These commands reproduce the GM.22 publication evidence from a fresh checkout.
Use the reviewed GM.22 commit or merge commit, not an unreviewed moving branch.
Generated evidence stays under `.scratch/`.

## Fresh clone

```sh
git clone https://github.com/jbwinters/jacquard-lang.git
cd jacquard-lang
git checkout <reviewed-gm22-commit>

asdf install opam 2.5.1
asdf set opam 2.5.1
opam init -y --no-setup --bare
opam switch create . ocaml-base-compiler.5.1.1 -y
eval "$(opam env)"
opam install --deps-only . --with-test --with-dev-setup --with-doc -y

mkdir -p "$PWD/.scratch"
export TMPDIR="$(mktemp -d -p "$PWD/.scratch" gm22-repro-tmp.XXXXXX)"
```

`<reviewed-gm22-commit>` is intentionally supplied by the release or PR record:
embedding a moving branch name here would not select immutable evidence.

## Publication gate

```sh
opam exec -- dune build @all
opam exec -- dune runtest --force
opam exec -- dune build @fmt
git diff --exit-code
opam exec -- dune build @doc

(
  cd playground/governance
  corepack enable
  pnpm install --frozen-lockfile
  pnpm run lint
  pnpm run typecheck
  pnpm run test
  pnpm run build
  pnpm exec playwright install chromium firefox webkit
  pnpm run test:e2e
)

sh demos/governed-workspace/run.sh
opam exec -- dune runtest test/cli/governed-workspace.t --force

opam exec -- dune build @gm12b-evidence
opam exec -- dune runtest test/cli/governance-replay.t --force

CC=clang opam exec -- sh scripts/native-diff.sh
JACQUARD_RELEASE_REF=HEAD JACQUARD_RELEASE_BASE=738dc8e \
  scripts/release/reproduce-0.1.sh

scripts/release/check-governed-membranes-manifest.sh
```

The ordinary full `runtest` executes every compiled governance, Workspace,
Approval, Audit, Secret, run-bundle, reconciliation, source-gate, explanation,
attribution, review-diff, and gauntlet suite plus all cram transcripts. The
separate GM.12B alias is mandatory because its 50,000 real-handler cases are
deliberately too slow for the ordinary development alias. GM.15's
349-site/698-path exhaustive lane is executed by `governance-replay.t` and again by the
flagship launcher.

The Core 0.1 reproduction is retained because GM.22 is a successor overlay. It
proves that the full historical build, runtime memory checks, clang native
differential/leak/fuzz lanes, public demos, and adversarial gauntlets remain
green; it does not reinterpret the historical Core 0.1 claims.

The playground commands use the exact Node active-LTS and pnpm versions pinned
in `playground/governance/package.json`. Browser installation may download the
pinned Playwright engines; the application itself remains loopback-only and
the browser lane fails if it observes a non-loopback application request.

## Focused governance diagnosis

When a full gate fails, this narrower command preserves all compiled governance
families without rerunning unrelated language suites:

```sh
cd _build/default/test
./test_jacquard.exe test \
  'effect-taxonomy|audit|secret|approval|governance-.*|judge|workspace.*|gauntlet-.*' \
  --compact --color=never
cd ../../..
```

Focused public transcripts can be run with:

```sh
opam exec -- dune runtest \
  test/cli/governance-check.t \
  test/cli/why-effect.t \
  test/cli/governance-explain.t \
  test/cli/governance-reconciliation.t \
  test/cli/governance-replay.t \
  test/cli/governed-workspace.t \
  test/cli/governed-membranes-release.t \
  --force
```

## Inventory and outputs

```sh
find test -name '*.t' | sort | wc -l
find test/docs-doctest/fixtures -name '*.jac' | sort | wc -l
git rev-parse HEAD
```

Expected source inventory at GM.22 is 799 compiled cases, 50 cram transcript
files, and 27 executable documentation examples. The mandatory `dune runtest`
above prints `Test Successful ... 799 tests run`; use that action-owned summary
rather than invoking the test binary outside Dune's staged prelude environment.
The doctest runner remains the authority for the documented 27 examples across
8 documents; the fixture file count is only a quick diagnostic.

To retain transcripts without writing outside the repository:

```sh
mkdir -p .scratch/release/governed-membranes/transcripts
sh demos/governed-workspace/run.sh \
  >.scratch/release/governed-membranes/transcripts/flagship.txt 2>&1
```
