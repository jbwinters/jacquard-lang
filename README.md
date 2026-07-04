# Weft

Weft is a research prototype for a small kernel language designed for code written by models and reviewed by people. The core design combines a uniform quoted triple representation, a 27-form kernel grammar, algebraic effects, explicit capability grants, probabilistic programming as a library effect, and content-addressed definitions.

All five milestones (M0-exec through M4) are implemented: the executable data layer, the CPS interpreter with multi-shot handlers, the type-and-effect checker with the capability manifest, probabilistic inference as handlers, and the tooling (formatter, semantic differ, error catalog, demos).

## Repository Layout

- `docs/whitepaper.tex` - project thesis, design motivation, roadmap, risks, and related work.
- `docs/ast.md` - M0 kernel AST draft and metadata/hash contract.
- `docs/development-plan.md` - implementation plan from W0.1 through W5.5.
- `docs/example-code.md` - target bootstrap `.wft` examples for the future corpus.
- `.taskmaster/` - local Task Master plan generated from `docs/development-plan.md`.
- `dune-project` and `weft.opam` - OCaml package and build metadata.
- `src/` - the `weft` library: `form`/`meta`/`span` (the triple), `hash` (HASH_V0), `reader`/`printer` (bootstrap notation + trivia-preserving formatter), `kernel` (grammar validator + typed AST), `resolve`, `canon` (canonical serialization + hashing), `store`, `value`/`eval` (CPS machine with multi-shot handlers), `prelude` (loader + grants), `types`/`check` (rows, inference, exhaustiveness, manifest), `diff` (semantic differ), `infer_dist` (enumeration + likelihood weighting).
- `bin/` - the `weft` CLI: `run` (with `--allow` capability grants), `check` (`--print-sigs`, `--manifest`), `hash`, `fmt`, `diff`, `infer enumerate|lw`, `store add|name|rename`.
- `test/` - alcotest/qcheck suites, the corpus runner, cram CLI tests, and the golden generators.
- `spec/` - the M0 kernel AST spec and `serialization.md` (canonical byte format).
- `corpus/` - conformance corpus (`valid/`, `invalid/` + `.expect`, `golden/` including prelude hashes).
- `prelude/` - the Weft prelude (`.wft` sources: types, effects, builtins, library functions).
- `demos/` - `m1.sh` (factorial, multi-shot choose, gated eval), `m3.sh` (Demo 1: inference as handlers), `m4-hostile.sh` (Demo 2: the hostile function).
- `docs/tutorial.md` - ten runnable examples; `docs/errors.md` - every diagnostic code.

## Toolchain

This repo uses asdf for `opam`, and opam for the OCaml compiler and OCaml packages.

Pinned asdf tool:

```bash
asdf current opam
```

Repo-local OCaml switch:

```bash
eval "$(opam env)"
opam switch show
ocaml -version
dune --version
```

Expected versions after setup:

- `opam` 2.5.1, via asdf
- OCaml 5.1.1, via the repo-local opam switch in `_opam/`
- `dune` 3.24.0
- `ocamlformat` 0.29.0

Core OCaml packages installed in the local switch:

- `alcotest`
- `cmdliner`
- `digestif`
- `dune`
- `menhir`
- `ocamlformat`
- `qcheck`

Developer-only tools installed in the same switch:

- `ocaml-lsp-server` for editor integration
- `utop` for an OCaml REPL
- `odoc` for generated API documentation

## Setup From This Checkout

If the local switch already exists:

```bash
cd /home/josh/dev/friendmachine/research/weft-lang
eval "$(opam env)"
```

If recreating the environment from scratch:

```bash
asdf plugin add opam https://github.com/asdf-community/asdf-opam.git
asdf install opam 2.5.1
asdf set opam 2.5.1
asdf reshim opam 2.5.1

opam init -y --no-setup --bare
opam switch create . ocaml-base-compiler.5.1.1 -y
eval "$(opam env)"

opam install -y dune alcotest qcheck digestif ocamlformat menhir cmdliner ocaml-lsp-server utop odoc
```

`_opam/` is intentionally ignored because it is a large local build artifact.

## Task Plan

Task Master has been populated from `docs/development-plan.md`.

Useful commands:

```bash
task-master list --format compact
task-master next
task-master show 1
task-master validate-dependencies
```

All 33 tasks (W0.1 through W5.5) are done.

## Implementation Milestones

- M0-exec: executable spec with parser, validator, resolver, hashing, store, and conformance corpus.
- M1: CPS interpreter with multi-shot resumptions, quote/unquote, gated eval, prelude, and CLI.
- M2: type and effect checker with row inference, exhaustiveness, diagnostics, and root capability manifest.
- M3: discrete `Dist` effect with enumeration and likelihood-weighting handlers.
- M4: formatter, semantic differ, error audit, docs, and final demos.

## The Two Demos

- **Demo 1 (M3): inference as handlers.** `sh demos/m3.sh` runs the two-coins model under
  exact enumeration and likelihood weighting; the model file is byte-identical between the
  two runs — only the handler changes.
- **Demo 2 (M4): the hostile function.** `sh demos/m4-hostile.sh` shows a generated-looking
  function that reaches for the network: `weft check` refuses it at the type level with its
  full signature; the granted run succeeds against the stub handler.

`docs/tutorial.md` walks ten runnable examples from literals to content addressing.

## Current Status

The plan is complete through M4. Programs parse to uniform triples, validate against the 27-form kernel, resolve to content hashes, and hash canonically; the CPS interpreter runs them with deep multi-shot handlers and capability grants as the only root authority; the checker infers types and effect rows (a signature carries the whole story, and `weft run` refuses ungranted effects at the type level); `weft infer` runs exact enumeration and likelihood weighting as handlers over unchanged models; and the tooling closes the loop with a trivia-preserving formatter, a semantic differ over stores, a complete error catalog, and the two whitepaper demos green in CI.

The tree should verify with:

```bash
eval "$(opam env)"
opam exec -- dune build @all
opam exec -- dune runtest
opam exec -- dune fmt
git diff --exit-code
task-master next
```

## CI/CD

GitHub Actions has two lanes:

- `CI / Development gate` for PRs, `main`, and `release/**`: build, full tests,
  clean formatting, version smoke, and release-doc presence.
- `Release Evidence / Reproduce 0.1 evidence` for `release/**`, `weft-core-*`
  tags, and manual dispatch: runs `scripts/release/reproduce-0.1.sh` and uploads
  release transcripts as an artifact.

See `docs/ci-cd.md` for required branch protection and the release-candidate
process.
