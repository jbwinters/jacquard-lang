# Agent Notes

This repository is an implemented OCaml research prototype in release-hardening
mode. Treat it as a semantic artifact with evidence, not as a greenfield
language project. Before editing code, read:

1. `README.md`
2. `docs/README.md`
3. `docs/development-plan.md`
4. `docs/ast.md`
5. `docs/release/0.1/EVIDENCE.md`

The original development plan has been completed. Use Task Master only for
local historical context unless the user explicitly asks for it.

```bash
task-master next
task-master show <id>
task-master set-status <id> in-progress
task-master validate-dependencies
```

## Tooling

Use asdf only to provide `opam`. Use the repo-local opam switch for OCaml and OCaml packages.

Run this before OCaml commands in a fresh shell:

```bash
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp"
export TMPDIR="$PWD/.scratch/tmp"
```

Keep temporary clones, worktrees, release reproductions, and generated test
stores under `.scratch/` in this repository. The root filesystem is small: do
not create Jacquard workspaces or build artifacts under `/tmp`.

Expected local toolchain:

- `opam` 2.5.1 from `.tool-versions`
- OCaml 5.1.1 from the repo-local switch
- `dune`
- `alcotest`
- `qcheck`
- `digestif`
- `ocamlformat`
- `menhir`
- `cmdliner`
- `ocaml-lsp-server`
- `utop`
- `odoc`

Core commands for the current scaffold:

```bash
eval "$(opam env)"
opam exec -- dune build
opam exec -- dune build @all
opam exec -- dune test
opam exec -- dune runtest
opam exec -- dune fmt
git diff --exit-code
opam exec -- dune build @doc
```

The implementation is in `src/` with suites in `test/`. Verify the environment with:

```bash
eval "$(opam env)"
ocaml -version
dune --version
opam exec -- dune build @all
opam exec -- dune runtest
```

When adding valid corpus files, regenerate the golden hashes with
`opam exec -- dune exec test/gen_goldens.exe` and commit the diff (see
`corpus/README.md`).

## Working Rules

- Preserve the release-hardening posture unless the user explicitly asks for
  feature work.
- Start from existing tests and docs. Jacquard behavior is pinned by cram
  transcripts, Alcotest/QCheck suites, corpus goldens, demos, and release docs.
- Keep behavior tied to the 27 kernel forms in `docs/ast.md`. Public `.jac`
  syntax must remain a projection onto those forms, and bootstrap `.jqd`
  remains the permanent kernel/debug carrier.
- Do not add out-of-scope features from the plan guardrails: performance work, macros beyond quote/unquote/gated eval, records, typed staging, continuous distributions, package management, self-hosting, or ownership/borrowing.
- Use `dune`, `alcotest`, and `qcheck` for build and tests.
- Use `digestif` for the initial hash implementation unless the owner changes D1.
- Use `menhir` for the bootstrap reader if a generated parser is needed.
- Use `cmdliner` for the CLI.
- Use `ocamlformat` for formatting once the project has a formatter config.
- Public functions in touched modules should have doc comments describing contracts and failure modes.
- Library code should return `('a, Diag.t list) result`; exceptions are only for internal invariant failures and should be prefixed `Bug_`.

## Where To Look

- Fresh-clone setup and common commands: `README.md`.
- Documentation map: `docs/README.md`.
- Runtime examples: `docs/tutorial.md`.
- Demo catalog: `demos/README.md`.
- CI and release process: `docs/ci-cd.md`.
- Release evidence: `docs/release/0.1/`.
- Kernel and hashing rules: `docs/ast.md`, `spec/serialization.md`,
  `src/canon.ml`.
- Effects and capabilities: `prelude/03-effects.jqd`, `src/check.ml`,
  `src/prelude.ml`.
- Handlers and evaluation: `src/eval.ml`, `test/test_handlers.ml`,
  `test/test_gauntlet_handlers.ml`.
- Dist and inference: `prelude/06-dist.jqd`, `prelude/13-dist-lib.jqd`,
  `src/infer_dist.ml`, `test/test_infer.ml`.
- Warp: `prelude/15-warp.jqd`, `prelude/16-gen.jqd`, `src/warp.ml`,
  `test/cli/warp.t`, `test/cli/props.t`.

## Git Hygiene

- `_opam/` is a local switch and must stay ignored.
- `.scratch/` is repo-local disposable workspace state and must stay ignored.
- `.taskmaster/` is currently ignored in this repo. Task Master data is available locally but will not be committed unless the ignore policy changes.
- Do not rewrite unrelated dirty worktree changes.

## CI/CD Expectations

GitHub Actions mirrors the local definition of done:

- `CI / Development gate` runs build, full tests, clean formatting, version
  smoke, and release-doc presence on PRs, `main`, and `release/**`.
- `Release Evidence / Reproduce 0.1 evidence` runs
  `scripts/release/reproduce-0.1.sh` on `release/**`, `jacquard-core-*` tags, and
  manual dispatch, then uploads the evidence transcripts.

Release-facing changes should keep `scripts/release/reproduce-0.1.sh` green and
should not add features outside the release hardening scope.

## Decisions To Preserve

The plan assumes these defaults until the owner decides otherwise:

- D1: SHA-256 via `digestif`, named `HASH_V0`, swappable.
- D2: OCaml native 63-bit int; overflow wraps and is documented.
- D3: UTF-8 text, no normalization.
- D4: seedable splittable PRNG via a `splitmix64` port, seed required in CLI.
- D5: uncurried final call convention.
- D6: private until M1 demo.
