# CI/CD

Weft's CI is intentionally a release discipline, not just a build bot. The
project rule is that nothing merges unless the definition-of-done evidence is
machine-checkable.

## Development Gate

Workflow: `.github/workflows/ci.yml`

Runs on pull requests, pushes to `main`, pushes to `release/**`, and manual
dispatch.

Required check for protected branches:

- `CI / Development gate`

The gate runs:

```sh
opam install --deps-only . --with-test --with-doc --with-dev-setup -y
opam exec -- dune build @all
opam exec -- dune runtest
opam exec -- dune fmt
git diff --exit-code
_build/default/bin/main.exe --version
```

The `dune fmt` plus `git diff --exit-code` pair is deliberate: if formatting
auto-promotes anything, CI fails and prints the diff.

## Release Evidence

Workflow: `.github/workflows/release-evidence.yml`

Runs on:

- pushes to `release/**`
- tags named `weft-core-*`
- manual dispatch with a chosen branch, tag, or commit

Required check before tagging release candidates:

- `Release Evidence / Reproduce 0.1 evidence`

The workflow runs:

```sh
WEFT_RELEASE_REF=HEAD \
WEFT_RELEASE_BASE=3609a67 \
scripts/release/reproduce-0.1.sh
```

It uploads the release docs and generated transcripts from `logs/release/0.1/`
as a GitHub Actions artifact. That artifact is the reproducible evidence pack
for review.

## Recommended Branch Protection

For `main`:

- require pull requests before merging
- require `CI / Development gate`
- require branches to be up to date before merging
- dismiss stale approvals when new commits are pushed

For `release/**`:

- require `CI / Development gate`
- require `Release Evidence / Reproduce 0.1 evidence`
- restrict changes to correctness, reproducibility, documentation, and demos

For `weft-core-*` tags:

- create tags only after the release evidence workflow is green for the exact
  commit being tagged
- preserve the uploaded evidence artifact with the tag/release notes

## Local Equivalents

Before opening an ordinary PR:

```sh
eval "$(opam env)"
opam exec -- dune build @all
opam exec -- dune runtest
opam exec -- dune fmt
git diff --exit-code
```

Before asking for a release-candidate review:

```sh
WEFT_RELEASE_REF=release/0.1-evidence scripts/release/reproduce-0.1.sh
```
