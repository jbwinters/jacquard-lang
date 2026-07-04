# Agent Notes

This repository is a pre-implementation OCaml language prototype. Read the docs before editing code:

1. `docs/development-plan.md`
2. `docs/ast.md`
3. `docs/example-code.md`
4. `docs/whitepaper.tex`

The development plan is already loaded into Task Master. Use it as the execution queue.

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
```

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

The data layer (M0-exec, tasks W0.1-W1.7) is implemented in `src/` with suites in `test/`. Verify the environment and task queue with:

```bash
eval "$(opam env)"
ocaml -version
dune --version
opam exec -- dune build @all
opam exec -- dune runtest
task-master next
```

When adding valid corpus files, regenerate the golden hashes with `dune exec test/gen_goldens.exe` and commit the diff (see `corpus/README.md`).

## Working Rules

- Follow `docs/development-plan.md` in phase order unless a task explicitly says it is parallel-safe.
- Keep behavior tied to the 27 kernel forms in `docs/ast.md`; do not add surface syntax beyond the bootstrap `.wft` notation in W1.2.
- Do not add out-of-scope features from the plan guardrails: performance work, macros beyond quote/unquote/gated eval, records, typed staging, continuous distributions, package management, self-hosting, or ownership/borrowing.
- Use `dune`, `alcotest`, and `qcheck` for build and tests.
- Use `digestif` for the initial hash implementation unless the owner changes D1.
- Use `menhir` for the bootstrap reader if a generated parser is needed.
- Use `cmdliner` for the CLI.
- Use `ocamlformat` for formatting once the project has a formatter config.
- Public functions in touched modules should have doc comments describing contracts and failure modes.
- Library code should return `('a, Diag.t list) result`; exceptions are only for internal invariant failures and should be prefixed `Bug_`.

## Git Hygiene

- `_opam/` is a local switch and must stay ignored.
- `.taskmaster/` is currently ignored in this repo. Task Master data is available locally but will not be committed unless the ignore policy changes.
- Do not rewrite unrelated dirty worktree changes.

## CI/CD Expectations

GitHub Actions mirrors the local definition of done:

- `CI / Development gate` runs build, full tests, clean formatting, version
  smoke, and release-doc presence on PRs, `main`, and `release/**`.
- `Release Evidence / Reproduce 0.1 evidence` runs
  `scripts/release/reproduce-0.1.sh` on `release/**`, `weft-core-*` tags, and
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
