# Weft

Weft is a research prototype for running, reviewing, simulating, and trusting
programs written by models and reviewed by people.

The core idea is simple: effects, uncertainty, and identity should be visible to
tools instead of hidden in runtime behavior, mocks, logs, prompts, or naming
conventions. A Weft program can run under real handlers, dry-run handlers,
replay handlers, simulated handlers, probabilistic handlers, and test handlers
without changing the policy code.

Core ingredients:

- a uniform quoted triple representation and 27-form kernel grammar
- algebraic effects with deep multi-shot handlers
- explicit capability grants; no ambient root handlers
- type-and-effect rows where `main` is the authority manifest
- discrete probabilistic programming as ordinary effects and handlers
- content-addressed definitions with metadata-erased identity
- tooling for formatting, semantic diff, Warp tests, replay, demos, and release
  evidence

The implementation is complete through the original M0-exec through M4 plan:
the executable data layer, CPS interpreter, checker, capability manifest,
`Dist` inference handlers, formatter, semantic differ, error catalog, demos, and
release-candidate evidence pack are all present.

## Quick Start

These commands assume a fresh clone and `asdf` available for installing `opam`.
If you already have `opam` 2.5.x, start at the local switch step. If `opam`
is already initialized on your machine, skip `opam init`.

```bash
git clone https://github.com/jbwinters/weft-lang.git
cd weft-lang

asdf plugin add opam https://github.com/asdf-community/asdf-opam.git
asdf install opam 2.5.1
asdf set opam 2.5.1
asdf reshim opam 2.5.1

opam init -y --no-setup --bare
opam switch create . ocaml-base-compiler.5.1.1 -y
eval "$(opam env)"

opam install --deps-only . --with-test --with-dev-setup --with-doc -y
opam exec -- dune build @all
opam exec -- dune runtest
opam exec -- dune fmt
git diff --exit-code
```

The final `git diff --exit-code` is part of the development contract: formatting
must leave the worktree clean unless you intentionally commit the formatting
diff.

Expected versions after setup:

- `opam` 2.5.1 from `.tool-versions`
- OCaml 5.1.1 from the repo-local `_opam/` switch
- `dune`, `ocamlformat`, `alcotest`, `qcheck`, `digestif`, `menhir`,
  `cmdliner`, `odoc`, `utop`, and `ocaml-lsp-server` from `weft.opam`

In a new shell inside an existing checkout, run:

```bash
eval "$(opam env)"
```

`_opam/` is intentionally ignored. It is a local build artifact, not source.

## Running Weft

During development, use the built binary through Dune:

```bash
opam exec -- dune exec weft -- --help
opam exec -- dune exec weft -- --version
```

Many direct CLI commands need the prelude. From the repository root:

```bash
export WEFT_PRELUDE=$PWD/prelude
opam exec -- dune exec weft -- run demos/m1-fact.wft
```

The main commands are:

```bash
weft run FILE.wft [--allow fs] [--allow net] [--dry-run]
weft check FILE.wft [--print-sigs] [--manifest fs,net,console]
weft hash FILE.wft
weft fmt FILE.wft
weft diff STORE_A STORE_B
weft infer enumerate MODEL.wft
weft infer lw MODEL.wft --seed 42 --samples 100000
weft replay TRACE.wft PROGRAM.wft [--fork '1=(response 500 "down")']
weft test TESTS.wft [--exhaustive] [--cache-dir CACHE]
```

## Demos

Start with these from the repo root:

```bash
export WEFT_PRELUDE=$PWD/prelude
opam exec -- sh demos/m1.sh
opam exec -- sh demos/m3.sh
opam exec -- sh demos/clarifying-question.sh
opam exec -- sh demos/agent-dream.sh
opam exec -- sh demos/ambiguity-pipeline.sh
opam exec -- sh demos/showcase-warp-tests.sh
opam exec -- sh demos/m4-hostile.sh
```

What they show:

- `m1.sh`: factorial, multi-shot choice, and gated eval.
- `m3.sh`: one model under exact enumeration and likelihood weighting; same
  model hash, different inference handler.
- `clarifying-question.sh`: value-of-information for asking the user.
- `agent-dream.sh`: one policy under scripted and probabilistic world handlers.
- `ambiguity-pipeline.sh`: posterior-carrying extraction; user selection is an
  `observe`.
- `showcase-warp-tests.sh`: Warp checks for the VOI, dream-mode, and ambiguity
  demos.
- `m4-hostile.sh`: generated-looking code that reaches for `net`; signatures and
  manifests expose the authority.
- `demos/escrow/`: product-shaped generated workflow with manifest, dry-run,
  Warp tests, fault exploration, replay, semantic diff, and approval by hash.

All public demo outputs are pinned by cram tests, especially
`test/cli/demos.t`, `test/cli/hostile-demo.t`, and `test/cli/escrow.t`.

## Release Evidence

The release-candidate evidence pack lives in `docs/release/0.1/`.

To reproduce the release evidence from this checkout:

```bash
WEFT_RELEASE_REF=HEAD WEFT_RELEASE_BASE=aec2c63 scripts/release/reproduce-0.1.sh
```

The script installs dependencies, builds, runs the full test suite, checks
formatting, runs public demos, runs gauntlet tests, records `weft --version`,
and writes transcripts under `logs/release/0.1/`.

Key release docs:

- `docs/release/0.1/EVIDENCE.md`: what was built and what passed
- `docs/release/0.1/CLAIMS.md`: semantic claims mapped to tests and caveats
- `docs/release/0.1/REPRO.md`: fresh-clone reproduction steps
- `docs/release/0.1/FREEZE.md`: frozen version/hash/store/CLI surfaces
- `docs/release/0.1/GAUNTLET.md`: adversarial tests present and omitted
- `docs/release/0.1/LIMITS.md`: explicit non-goals and caveats
- `docs/release/0.1/DECISION.md`: release-candidate decision memo

## Repository Map

- `.github/`: CI, release evidence workflow, and PR template.
- `AGENTS.md`: operating notes for future coding agents.
- `bin/`: `weft` CLI entry point.
- `corpus/`: conformance corpus and golden outputs.
- `demos/`: runnable examples and product-shaped demos.
- `docs/`: design docs, tutorial, CI/CD, Warp, stdlib, errors, release evidence.
- `prelude/`: Weft standard library and effect declarations.
- `scripts/release/`: reproducible release evidence script.
- `spec/`: kernel AST and canonical serialization specs.
- `src/`: OCaml implementation.
- `test/`: Alcotest/QCheck suites plus cram CLI transcripts.
- `weft.opam`, `dune-project`: package and build metadata.

## Implementation Map

- `src/form.ml`, `src/meta.ml`, `src/span.ml`: uniform triple and metadata.
- `src/reader.ml`, `src/printer.ml`: bootstrap `.wft` notation and formatter.
- `src/kernel.ml`: validator and typed kernel AST.
- `src/resolve.ml`: names to content-addressed references.
- `src/canon.ml`, `src/hash.ml`: HASH_V0 canonical serialization and hashing.
- `src/store.ml`: object store and mutable name index.
- `src/value.ml`, `src/eval.ml`: CPS evaluator and multi-shot handlers.
- `src/types.ml`, `src/check.ml`: type/effect inference, rows, manifests,
  exhaustiveness.
- `src/prelude.ml`: prelude loader, builtin wiring, and root grants.
- `src/infer_dist.ml`: exact enumeration and likelihood weighting.
- `src/diff.ml`: semantic diff over stores.
- `src/warp.ml`: Warp test discovery, running, cache, and properties.

## Documentation Map

Read these in order if you are new:

1. `docs/README.md`: documentation index and suggested reading paths.
2. `docs/tutorial.md`: runnable user-facing examples.
3. `demos/README.md`: demo catalog and what each demo proves.
4. `docs/ci-cd.md`: GitHub checks and release evidence process.
5. `docs/release/0.1/EVIDENCE.md`: release-candidate evidence overview.

Deeper design references:

- `docs/whitepaper.tex`: thesis, motivation, roadmap, and risks.
- `docs/ast.md`: kernel AST and metadata/hash contract.
- `spec/weft-kernel-ast-m0.md`: kernel source-of-truth spec.
- `spec/serialization.md`: canonical byte format.
- `docs/stdlib.md`: prelude and ringed standard library.
- `docs/warp-testing.md`: Warp testing model.
- `docs/errors.md`: diagnostic catalog.
- `docs/development-plan.md`: original implementation plan.

## Development Workflow

Before opening a PR:

```bash
eval "$(opam env)"
opam exec -- dune build @all
opam exec -- dune runtest
opam exec -- dune fmt
git diff --exit-code
```

When adding valid corpus files, regenerate golden hashes:

```bash
opam exec -- dune exec test/gen_goldens.exe
```

When touching release-facing demos, claims, CI, or semantics, also run:

```bash
WEFT_RELEASE_REF=HEAD WEFT_RELEASE_BASE=aec2c63 scripts/release/reproduce-0.1.sh
```

## CI/CD

GitHub Actions has two lanes:

- `CI / Development gate`: build, full tests, clean formatting, version smoke,
  and release-doc presence on PRs, `main`, and `release/**`.
- `Release Evidence / Reproduce 0.1 evidence`: release branches, `weft-core-*`
  tags, and manual dispatch; runs `scripts/release/reproduce-0.1.sh` and uploads
  transcripts.

See `docs/ci-cd.md` for branch protection recommendations.

## Current Limits

Weft core 0.1 is a research prototype, not a production compiler. It does not
claim surface syntax beyond bootstrap `.wft`, a VM or optimizer, continuous
distributions, gradients, typed staging, package management, self-hosting, or a
formal proof of row soundness. See `docs/release/0.1/LIMITS.md` for the
no-hype list.

## Troubleshooting

- `opam: command not found`: install `opam` with asdf using `.tool-versions`, or
  install a compatible `opam` manually.
- Dune cannot find packages: run `eval "$(opam env)"` in this shell, then
  reinstall deps with `opam install --deps-only . --with-test --with-dev-setup
  --with-doc -y`.
- `weft` cannot find names from the prelude: set `WEFT_PRELUDE=$PWD/prelude` or
  run through Dune from the repo root.
- Formatting changed files: run `opam exec -- dune fmt`, inspect the diff, and
  commit the formatting changes if they are intended.
- Release reproduction writes files under `logs/`: that directory is ignored and
  contains generated transcripts only.
