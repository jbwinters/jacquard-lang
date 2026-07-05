# Weft

Weft is a research prototype for running, reviewing, simulating, and trusting
programs written by models and reviewed by people.

Concretely, it is a small programming language: Lisp-style syntax, an
interpreter and type checker written in OCaml, a command-line tool, a standard
library, and a test framework called Warp. Version 0.1 works end to end but is
a research prototype, not a production language; `docs/release/0.1/LIMITS.md`
is the honest list of what it does not do.

## For Humans

Most languages tell you what a program computes. Weft also tells you what a
program is allowed to do, how certain it is, and whether two pieces of code
mean the same thing. Tools can check all three, because they live in the
language instead of in comments, logs, or your memory of the codebase.

Things you can do here that most languages cannot offer:

- Read one line and know a function's full reach. A signature like
  `(text) ->{net} text` says this function touches the network. The program
  will not run until you grant each power it asks for with `--allow`, so
  generated code cannot quietly open a connection or write a file. If you do
  not grant `net`, no code in the program can reach the network, including
  code the program builds and runs at runtime.
- Run one program against many worlds. The same code can run against the real
  network, a scripted fake, a recording of last week's traffic, or a
  probability model of how servers usually behave. A handler is the piece
  that answers a program's requests to the outside world; you swap the
  handler, and the code never changes. This replaces mocking frameworks, and
  it makes "what would my agent do if the API went down?" an ordinary test.
- Ask for exact odds. Probability is part of the language. A program can
  sample weighted choices and record evidence, and Weft will list every
  possible outcome with its exact chance. The repair demo below uses this to
  treat a failing test as evidence: it computes which patches to a buggy
  program remain possible, and how likely each one is.
- Rename and reformat for free. Weft identifies code by a hash of its meaning,
  not its text. Comments and formatting never break a build or a cache, and
  pure tests rerun only when the meaning of something they depend on changed.

The bet behind all of this: when most code is written by machines, the humans
reviewing it need the language itself to answer "what can this touch, and how
sure are we" without reading every line.

## For Agents

Read `docs/SKILL.md` first. It compresses the kernel, the CLI, the prelude,
Warp testing, and the known gotchas into one file, and it loads as a project
skill from `docs/SKILL.md`. Operating rules are in `AGENTS.md`. What
will save you time:

- Behavior is pinned by evidence: cram transcripts under `test/cli/`, corpus
  goldens, demo scripts, and `docs/release/0.1/CLAIMS.md`. If a pin fails,
  treat it as information about your change, and never weaken a pin to make a
  diff pass.
- The kernel is 27 forms (`docs/ast.md`); bootstrap s-expressions are the only
  syntax. Do not add surface syntax or out-of-scope features (`AGENTS.md`
  lists them).
- The development gate is `dune build @all && dune runtest && dune fmt`
  followed by a clean `git diff --exit-code`.

## Core Ingredients

For readers who speak programming languages:

- One uniform representation: every form is a `(head, meta, args)` triple, and
  the kernel grammar has 27 forms. Quoted code is ordinary data.
- Algebraic effects with deep, multi-shot handlers. A handler can resume a
  computation zero, one, or many times, which is what makes exhaustive search
  and exact inference ordinary library code.
- Explicit capability grants. The runtime installs handlers for the outside
  world only for effects you pass with `--allow`; there is no ambient
  authority.
- Type-and-effect rows. Every arrow carries the set of effects the function
  may perform, so a program's inferred row is its authority manifest.
- Discrete probabilistic programming as a library: `sample` and `observe` are
  effect operations, and each inference algorithm is a handler.
- Content-addressed definitions. Identity is a hash computed with all metadata
  erased, so a rename or reformat changes nothing downstream.
- Tooling that leans on the above: formatter, semantic differ, Warp tests with
  a semantic cache, record/replay, and a reproducible release evidence pack.

The prototype is complete against its original development plan: parser,
checker, CPS interpreter with multi-shot handlers, capability manifests, exact
and sampled inference, formatter, semantic differ, error catalog, demos, and
the release evidence pack all exist and are covered by tests.

## What It Looks Like

The bootstrap syntax is s-expressions over a uniform triple. Here is one
handler resuming one continuation twice (`demos/m1-choose.wft`):

```lisp
(handle
  (match (app (var choose))
    (clause (pcon true) (lit 1))
    (clause (pcon false) (lit 2)))
  (ret (pvar x) (app (var cons) (var x) (var nil)))
  (opclause choose () k
    (app (var append) (app (var k) (var true)) (app (var k) (var false)))))
```

```
$ weft run demos/m1-choose.wft
cons(1, cons(2, nil))
```

The handler ran the rest of the program once with `true` and once with
`false`, then collected both results. That ability to resume more than once is
why exact Bayesian inference is a library handler here rather than a runtime
feature. The repair demo builds on it: mutate a buggy program's quoted AST
into candidate patches, treat a failing test as an observation, and read off
the updated probabilities. Running candidate code is an authority, so the pure
step still runs (it counts eight candidate patches) and then the demo refuses
until you grant the rest:

```
$ weft run demos/repair.wft
8
error[E0814]: this program requires the `eval` effect, which is not granted (performed via `posterior-over-patches`)
  hint: grant it with --allow eval, or handle the effect in the program
$ weft run demos/repair.wft --allow eval
```

Under the grant, one failing test leaves two surviving patches: the intended
fix at 0.75 and a patch that games the suite at 0.25. Adding one regression
test prunes the impostor, and the surviving fix prints as a one-line semantic
diff: `- sub + add`. See `sh demos/repair.sh` for the full transcript.

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

The switch step compiles OCaml 5.1.1 from source, so expect the first setup to
take around ten minutes.

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
opam exec -- sh demos/repair.sh
opam exec -- sh demos/m4-hostile.sh
```

What they show:

- `m1.sh`: factorial, multi-shot choice, and gated eval.
- `m3.sh`: one model under exact enumeration and likelihood weighting; same
  model hash, different inference handler.
- `clarifying-question.sh`: an agent computes whether asking the user a
  question is worth the interruption (value of information).
- `agent-dream.sh`: one policy under scripted and probabilistic world handlers.
- `ambiguity-pipeline.sh`: an extraction pipeline that keeps its uncertainty;
  the user's click becomes an `observe`.
- `showcase-warp-tests.sh`: Warp checks for the clarifying-question,
  dream-mode, and ambiguity demos.
- `repair.sh`: program repair as Bayesian inference; a bug report is an
  observation over computed single-edit patches, and the most likely patch
  prints as a one-line semantic diff.
- `m4-hostile.sh`: generated-looking code that reaches for `net`; signatures and
  manifests expose the authority.
- `demos/escrow/`: product-shaped generated workflow with manifest, dry-run,
  Warp tests, fault exploration, replay, semantic diff, and approval by hash.

All public demo outputs are pinned by cram tests (recorded command-line
transcripts that fail on any drift), especially `test/cli/demos.t`,
`test/cli/hostile-demo.t`, `test/cli/escrow.t`, `test/cli/showcase.t`, and
`test/cli/repair.t`.

## Release Evidence

The release-candidate evidence pack lives in `docs/release/0.1/`.

To reproduce the release evidence from this checkout:

```bash
WEFT_RELEASE_REF=HEAD WEFT_RELEASE_BASE=3609a67 scripts/release/reproduce-0.1.sh
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
WEFT_RELEASE_REF=HEAD WEFT_RELEASE_BASE=3609a67 scripts/release/reproduce-0.1.sh
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
