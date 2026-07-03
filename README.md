# Weft

Weft is a research prototype for a small kernel language designed for code written by models and reviewed by people. The core design combines a uniform quoted triple representation, a 27-form kernel grammar, algebraic effects, explicit capability grants, probabilistic programming as a library effect, and content-addressed definitions.

The current repository is still pre-implementation. The design docs are the source of truth until W0.1 creates the first OCaml project scaffold.

## Repository Layout

- `docs/whitepaper.tex` - project thesis, design motivation, roadmap, risks, and related work.
- `docs/ast.md` - M0 kernel AST draft and metadata/hash contract.
- `docs/development-plan.md` - implementation plan from W0.1 through W5.5.
- `docs/example-code.md` - target bootstrap `.wft` examples for the future corpus.
- `.taskmaster/` - local Task Master plan generated from `docs/development-plan.md`.
- `dune-project` and `weft.opam` - OCaml package and build metadata.
- `src/`, `bin/`, `test/` - empty first-layer Dune directories; implementation stanzas land here later.
- `corpus/`, `spec/`, `prelude/`, `demos/` - planned data, spec, library, and demo directories.

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

The next task should be `W0.1 Repository scaffold and CI`.

## Implementation Milestones

- M0-exec: executable spec with parser, validator, resolver, hashing, store, and conformance corpus.
- M1: CPS interpreter with multi-shot resumptions, quote/unquote, gated eval, prelude, and CLI.
- M2: type and effect checker with row inference, exhaustiveness, diagnostics, and root capability manifest.
- M3: discrete `Dist` effect with enumeration and likelihood-weighting handlers.
- M4: formatter, semantic differ, error audit, docs, and final demos.

## Current Status

Implementation is underway on the M0-exec milestone (the data layer). The `weft` library, `weft` CLI (`weft --version`), and the alcotest/qcheck test suite exist; see Task Master for the live task queue.

The tree should verify with:

```bash
eval "$(opam env)"
dune build @all
dune runtest
dune fmt
task-master next
```
