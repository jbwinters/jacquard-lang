# Weft

Weft is a research prototype for a small kernel language designed for code written by models and reviewed by people. The core design combines a uniform quoted triple representation, a 27-form kernel grammar, algebraic effects, explicit capability grants, probabilistic programming as a library effect, and content-addressed definitions.

The M0-exec milestone (the executable data layer) is implemented: reader, printer, kernel validator, name resolution, canonical hashing, content-addressed store, and the conformance corpus harness. The design docs remain the source of truth for later milestones.

## Repository Layout

- `docs/whitepaper.tex` - project thesis, design motivation, roadmap, risks, and related work.
- `docs/ast.md` - M0 kernel AST draft and metadata/hash contract.
- `docs/development-plan.md` - implementation plan from W0.1 through W5.5.
- `docs/example-code.md` - target bootstrap `.wft` examples for the future corpus.
- `.taskmaster/` - local Task Master plan generated from `docs/development-plan.md`.
- `dune-project` and `weft.opam` - OCaml package and build metadata.
- `src/` - the `weft` library: `form`/`meta`/`span` (the triple), `hash` (HASH_V0), `reader`/`printer` (bootstrap notation), `kernel` (grammar validator + typed AST), `resolve`, `canon` (canonical serialization + hashing), `store`.
- `bin/` - the `weft` CLI (version stub until W2.7).
- `test/` - alcotest/qcheck suites plus the corpus runner and `gen_goldens` tool.
- `spec/` - the M0 kernel AST spec and `serialization.md` (canonical byte format).
- `corpus/` - conformance corpus (`valid/`, `invalid/` + `.expect`, `golden/`).
- `prelude/`, `demos/` - planned library and demo directories (M1+).

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

Tasks 1-9 (W0.1 through W1.7, the M0-exec milestone) are done; the next task is `W2.1 Runtime values and environments`.

## Implementation Milestones

- M0-exec: executable spec with parser, validator, resolver, hashing, store, and conformance corpus.
- M1: CPS interpreter with multi-shot resumptions, quote/unquote, gated eval, prelude, and CLI.
- M2: type and effect checker with row inference, exhaustiveness, diagnostics, and root capability manifest.
- M3: discrete `Dist` effect with enumeration and likelihood-weighting handlers.
- M4: formatter, semantic differ, error audit, docs, and final demos.

## Current Status

M0-exec is complete: the spec is executable. `.wft` sources parse to uniform triples, validate against the 27-form kernel grammar, resolve names to content hashes, and hash canonically (alpha- and meta-invariant, group-order-invariant); declarations round-trip through the on-disk store; and the conformance corpus pins all of it in CI, golden hashes included. The interpreter milestone (M1, tasks W2.x) is next.

The tree should verify with:

```bash
eval "$(opam env)"
dune build @all
dune runtest
dune fmt
task-master next
```
