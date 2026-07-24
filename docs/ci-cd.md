# CI/CD

Jacquard's CI is intentionally a release discipline, not just a build bot. The
project rule is that nothing merges unless the definition-of-done evidence is
machine-checkable.

## Development Gate

Workflow: `.github/workflows/ci.yml`

Runs on pull requests, pushes to `main`, pushes to `release/**`, and manual
dispatch.

Required check for protected branches:

- `CI / Development gate`

The required development gate waits for the separate
`CI / Governance playground` job. That dependency prevents the protected
check from becoming green while the local review surface is failing.

The gate runs:

```sh
scripts/release/check-historical-manifests.sh \
  --commit "$(git rev-parse HEAD)" \
  --require-history
scripts/release/test-historical-manifests.sh --commit "$(git rev-parse HEAD)"
opam install --deps-only . --with-test --with-doc --with-dev-setup -y
opam exec -- dune build @all
opam exec -- dune runtest
opam exec -- dune fmt
git diff --exit-code
_build/default/bin/main.exe --version
```

The `dune fmt` plus `git diff --exit-code` pair is deliberate: if formatting
auto-promotes anything, CI fails and prints the diff.

The historical-manifest gate attests the immutable commit named by
`GITHUB_SHA`, not the mutable runner worktree. The candidate commit must retain
the exact published effect-linearity, structured-concurrency, and SC.17
correction-pack manifest and checker bytes. The gate reconstructs each pinned
publication commit and runs that publication's checker inside the reconstructed
tree. Generated and untracked runner files are outside this evidence contract;
the separate formatting cleanliness check still rejects tracked worktree
changes.

The mutation test works only in disposable copies under `.scratch/tmp`. It
changes one retained digest in each legacy manifest and proves that the gate
rejects both candidates. A no-Git source archive cannot satisfy this
history-backed gate: full history is required so CI cannot confuse an
anchor-only diagnostic with publication reconstruction. The legacy EL and SC
manifests describe historical publication overlays, not today's checkout; run
their legacy checkers only in the corresponding reconstructed publication
trees. This was not merely a theoretical distinction when the gate was added:
at base commit `7cd3054652674eeaae4bfae8483c909819589f66`, direct current-tree
checks reported 123 EL mismatches and 60 legacy SC mismatches because later
successor work had legitimately changed listed files. Those observed counts
explain the choice of tree semantics; they are diagnostic history, not a
permanent gate contract.

## Governance Playground

The source-checkout-only Workspace v0 decision-chain viewer has its own CI
job. It uses the exact Node and pnpm versions pinned in
`playground/governance/package.json`, installs the committed lockfile without
updating it, and runs:

```sh
pnpm install --frozen-lockfile
pnpm run lint
pnpm run typecheck
pnpm run test
pnpm run build
pnpm exec playwright install --with-deps chromium firefox webkit
pnpm run test:e2e
```

Playwright covers Chromium, Firefox, and WebKit. Its tests pin keyboard
navigation, focus behavior, reduced-motion and forced-color presentation, and
the absence of non-loopback application requests. CI retains the static
`dist/` build as an artifact but does not deploy it.

The OCaml suite independently regenerates every checked-in viewer fixture in
memory and byte-compares it with the file consumed by the client. Regenerate
fixtures after a deliberate projection change with:

```sh
eval "$(opam env)"
JACQUARD_GOVERNANCE_PLAYGROUND_FIXTURES_OUT="$PWD/playground/governance/fixtures/generated" \
  opam exec -- dune exec test/gen_governance_playground_fixtures.exe
```

## GM.12B Exhaustive Forwarding Evidence

The reusable Workspace forwarding membrane has a separate required check:

- `CI / GM12B exhaustive forwarding evidence`

It runs the full 50,000-case grid through two real forwarding handlers and a
hermetic leaf, then byte-compares the result with the checked-in transcript.
The proof is kept out of ordinary `dune runtest` because its exhaustive runtime
would make the development loop unresponsive; it remains mandatory and cannot
silently degrade into a sampled test. The job retains the actual transcript as
an artifact and has a 240-minute fail-closed timeout. Pull requests and
`main` pushes outside its semantic dependency closure take a successful no-op
path. Unknown commit ranges fail closed by running the proof, and
`release/**` pushes and manual dispatches always rerun it.
Each `main` push has a unique, non-canceling workflow concurrency group so a
later unrelated push cannot replace the run responsible for an earlier
relevant range.

The proof owns a dedicated Dune rule in `test/gm12b/dune`, so changes to
unrelated cram dependencies do not enter its CI scope. Its conservative
dependency closure still includes the implementation, prelude, toolchain,
proof carrier and expected transcript, checker, workflow, and dedicated rule.

Local equivalent:

```sh
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp"
export TMPDIR="$PWD/.scratch/tmp"
opam exec -- dune build @test/gm12b/gm12b-evidence --force
```

## Release Evidence

Workflow: `.github/workflows/release-evidence.yml`

Runs on:

- pushes to `release/**`
- tags named `jacquard-core-*`
- manual dispatch with a chosen branch, tag, or commit

Required check before tagging release candidates:

- `Release Evidence / Reproduce 0.1 evidence`

The workflow runs:

```sh
JACQUARD_RELEASE_REF=HEAD \
JACQUARD_RELEASE_BASE=738dc8e \
scripts/release/reproduce-0.1.sh
```

It uploads the release docs and generated evidence from
`.scratch/release/0.1/` as a GitHub Actions artifact. That artifact is the
reproducible evidence pack for review.

## Release Binaries

Workflow: `.github/workflows/release-binaries.yml`

Runs on:

- tags named `jacquard-core-*`
- manual dispatch with a chosen branch, tag, or commit

The workflow builds release archives for:

- `linux-x86_64`
- `macos-x86_64`
- `macos-arm64`

Each archive contains:

- `bin/jacquard`: wrapper that sets `JACQUARD_PRELUDE` and `JACQUARD_RUNTIME`
- `bin/jac`: symlink alias to `jacquard`
- `libexec/jacquard/jacquard`: native executable
- `share/jacquard/prelude`: standard library
- `share/jacquard/demos`: runnable examples
- `share/jacquard/runtime`: C runtime sources used by `jac build`
- `LICENSE`, `NOTICE`, `RUNTIME-EXCEPTION.md`, `TRADEMARKS.md`, and package notes

Packaging verifies each archive checksum and runs the bundled factorial demo
through both the long command and the `jac` alias. It then removes Dune from
the effective tool path, runs the installed release-risk, agent-dream, and
escrow launchers, and compiles/runs a native `.jqd` program from the package.
The development gate also runs the installer end to end and proves that a
corrupted checksum fails closed.

On tag pushes, the workflow creates or updates the GitHub Release and attaches
the tarballs plus SHA-256 checksum files. Manual runs upload the same files as
workflow artifacts without creating a release.

Local equivalent:

```sh
eval "$(opam env)"
scripts/release/package-binary.sh
```

The public installer is `scripts/install.sh`; the current 0.1 RC copy defaults
to the exact `jacquard-core-0.1-rc3` tag and installs into `~/.local`. Set
`JACQUARD_INSTALL_VERSION` explicitly when testing another release.

## Recommended Branch Protection

For `main`:

- require pull requests before merging
- require `CI / Development gate`
- require `CI / GM12B exhaustive forwarding evidence`
- require branches to be up to date before merging
- dismiss stale approvals when new commits are pushed

For `release/**`:

- require `CI / Development gate`
- require `CI / GM12B exhaustive forwarding evidence`
- require `Release Evidence / Reproduce 0.1 evidence`
- restrict changes to correctness, reproducibility, documentation, and demos

For `jacquard-core-*` tags:

- create tags only after the release evidence workflow is green for the exact
  commit being tagged
- preserve the uploaded evidence artifact with the tag/release notes
- require the release-binaries workflow to complete before announcing the tag

## Local Equivalents

Before opening an ordinary PR:

```sh
eval "$(opam env)"
opam exec -- dune build @all
opam exec -- dune runtest
opam exec -- dune build @test/gm12b/gm12b-evidence --force
opam exec -- dune fmt
git diff --exit-code
(
  cd playground/governance
  corepack enable
  pnpm install --frozen-lockfile
  pnpm run lint
  pnpm run typecheck
  pnpm run test
  pnpm run build
  pnpm run test:e2e
)
```

Before asking for a release-candidate review:

```sh
JACQUARD_RELEASE_REF=HEAD scripts/release/reproduce-0.1.sh
```
