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
- tags named `jacquard-core-*`
- manual dispatch with a chosen branch, tag, or commit

Required check before tagging release candidates:

- `Release Evidence / Reproduce 0.1 evidence`

The workflow runs:

```sh
JACQUARD_RELEASE_REF=HEAD \
JACQUARD_RELEASE_BASE=aec2c63 \
scripts/release/reproduce-0.1.sh
```

It uploads the release docs and generated transcripts from `logs/release/0.1/`
as a GitHub Actions artifact. That artifact is the reproducible evidence pack
for review.

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

- `bin/jacquard`: wrapper that sets `JACQUARD_PRELUDE`
- `bin/jac`: symlink alias to `jacquard`
- `libexec/jacquard/jacquard`: native executable
- `share/jacquard/prelude`: standard library
- `share/jacquard/demos`: runnable examples
- `LICENSE` and package notes

On tag pushes, the workflow creates or updates the GitHub Release and attaches
the tarballs plus SHA-256 checksum files. Manual runs upload the same files as
workflow artifacts without creating a release.

Local equivalent:

```sh
eval "$(opam env)"
scripts/release/package-binary.sh
```

The public installer is `scripts/install.sh`; it downloads the right archive
from the latest release by default and installs into `~/.local`.

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
opam exec -- dune fmt
git diff --exit-code
```

Before asking for a release-candidate review:

```sh
JACQUARD_RELEASE_REF=release/0.1-evidence scripts/release/reproduce-0.1.sh
```
