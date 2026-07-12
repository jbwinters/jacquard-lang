# Jacquard

[![CI](https://github.com/jbwinters/jacquard-lang/actions/workflows/ci.yml/badge.svg)](https://github.com/jbwinters/jacquard-lang/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/jbwinters/jacquard-lang?include_prereleases&sort=semver)](https://github.com/jbwinters/jacquard-lang/releases)

Jacquard is a research prototype for running, reviewing, simulating, and trusting
programs written by models and reviewed by people.

Concretely, it is a small programming language with a compact `.jac` surface
syntax, an OCaml checker and CPS interpreter, a C-emitting native AOT compiler,
a command-line tool, a Jacquard-written standard library, and a test framework
called Warp. Version 0.1 works end to end but is a research prototype, not a
production language; `docs/release/0.1/LIMITS.md` is the honest boundary.

Install the 0.1 release candidate without OCaml or opam:

```bash
curl -fsSL https://raw.githubusercontent.com/jbwinters/jacquard-lang/jacquard-core-0.1-rc2/scripts/install.sh | sh
~/.local/bin/jac run ~/.local/share/jacquard/demos/basics/m1-fact.jac
```

The expected output is `120`. Linux x86-64, macOS Intel, and macOS Apple
Silicon binaries are published; development from source is documented below.

## For Humans

Most languages tell you what a program computes. Jacquard also tells you what a
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
  sample weighted choices and record evidence, and Jacquard will list every
  possible outcome with its exact chance. The repair demo below uses this to
  treat a failing test as evidence: it computes which patches to a buggy
  program remain possible, and how likely each one is.
- Rename and reformat for free. Jacquard identifies code by a hash of its meaning,
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
- The kernel is 27 forms (`docs/ast.md`); `.jac` is a projection onto those
  forms, and bootstrap `.jqd` remains permanently supported. Treat the shipped
  surface boundary and its parked follow-ups as release evidence, not as a
  frozen grammar; do not add out-of-scope features (`AGENTS.md` lists them).
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
- A native AOT path that emits C, specializes and caches units by content hash,
  and is differential-tested against the interpreter under clang and gcc.

The prototype is complete against its original core plan and has since added
the public surface syntax, ringed standard library, Warp properties and cache,
native compilation, packaged binaries, and product-scale case studies. RC1 is
pinned by 554 Alcotest/QCheck cases, 32 cram transcripts, 21 documentation
examples, native sanitizer/leak/fuzz lanes, and a fresh-clone evidence workflow.

## What It Looks Like

Here is one handler resuming one continuation twice. The block is copied
byte-for-byte to `test/docs-doctest/fixtures/readme-multishot.jac` and run by
the documentation test lane:

```jacquard doctest=readme-multishot mode=run fixture=readme-multishot.jac stdout=readme-multishot.stdout stderr=empty exit=0
effect Choice where {
  choose : () -> Bool
}

handle {
  match choose() {
    | True -> 1
    | False -> 2
  }
} {
  | return x -> x
  | choose() resume continue -> add(continue(True), continue(False))
}
```

```console
$ jac run test/docs-doctest/fixtures/readme-multishot.jac
3
```

The handler ran the rest of the program once with `true` and once with
`false`, then collected both results. That ability to resume more than once is
why exact Bayesian inference is a library handler here rather than a runtime
feature. The repair demo builds on it: mutate a buggy program's quoted AST
into candidate patches, treat a failing test as an observation, and read off
the updated probabilities. Running candidate code is an authority, so the pure
step still runs (it counts eight candidate patches) and then the demo refuses
until you grant the rest:

```console
$ jac run demos/tooling/repair.jac
8
error[E0814]: this program requires the `eval` effect, which is not granted (performed via `posterior-over-patches`)
  hint: grant it with --allow eval, or handle the effect in the program
$ jac run demos/tooling/repair.jac --allow eval
```

Under the grant, one failing test leaves two surviving patches: the intended
fix at 0.75 and a patch that games the suite at 0.25. Adding one regression
test prunes the impostor, and the surviving fix prints as a one-line semantic
diff: `- sub + add`. See `sh demos/tooling/repair.sh` for the full transcript.

## Install A Release Binary

Most users do not need OCaml or opam. Install the reviewed 0.1 RC binary with:

```bash
curl -fsSL https://raw.githubusercontent.com/jbwinters/jacquard-lang/jacquard-core-0.1-rc2/scripts/install.sh | sh
```

The installer detects your OS and CPU, downloads the matching archive and
SHA-256 checksum, refuses a checksum mismatch, and installs under `~/.local`
by default. Make sure `~/.local/bin` is on `PATH`, then run:

```bash
jacquard --version
jac --version
```

`jac` is the short alias for `jacquard`. Both commands set `JACQUARD_PRELUDE`
from the installed package, so ordinary runs do not need an environment variable:

```bash
jac run ~/.local/share/jacquard/demos/basics/m1-fact.jac
```

Narrative demos ship with launchers that choose the installed binary and
prelude automatically. They do not require Dune:

```bash
DEMO_ROOT="$HOME/.local/share/jacquard/demos"
sh "$DEMO_ROOT/case-studies/release-risk/run.sh"
sh "$DEMO_ROOT/worlds/agent-dream.sh"
sh "$DEMO_ROOT/worlds/escrow/run.sh"
```

Use these launchers rather than directly running a probabilistic model or a
multi-file entrypoint. The launcher selects `infer` where observation requires
it and assembles related files in isolated scratch space.

To install somewhere else:

```bash
JACQUARD_INSTALL_PREFIX=/usr/local sh scripts/install.sh
```

Set `JACQUARD_INSTALL_VERSION` to install a different release tag. Supported
binary targets are `linux-x86_64`, `macos-x86_64`, and `macos-arm64`; other
platforms currently require the development setup.

Release archives are attached to `jacquard-core-*` GitHub releases. Each
archive contains `bin/jacquard`, `bin/jac`, `libexec/jacquard/jacquard`,
`share/jacquard/prelude`, and `share/jacquard/demos`.

## Development Quick Start

These commands assume a fresh clone and `asdf` available for installing `opam`.
If you already have `opam` 2.5.x, start at the local switch step. If `opam`
is already initialized on your machine, skip `opam init`.

```bash
git clone https://github.com/jbwinters/jacquard-lang.git
cd jacquard-lang

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
  `cmdliner`, `odoc`, `utop`, and `ocaml-lsp-server` from `jacquard.opam`

In a new shell inside an existing checkout, run:

```bash
eval "$(opam env)"
```

`_opam/` is intentionally ignored. It is a local build artifact, not source.

## Running Jacquard

During development, use the built binary through Dune:

```bash
opam exec -- dune exec jac -- --help
opam exec -- dune exec jac -- --version
```

Many direct CLI commands need the prelude. From the repository root:

```bash
export JACQUARD_PRELUDE=$PWD/prelude
opam exec -- dune exec jac -- run demos/basics/m1-fact.jac
```

The main commands are:

```bash
jac run FILE.jac [--allow fs] [--allow net] [--dry-run]
jac check FILE.jac [--print-sigs] [--manifest fs,net,console]
jac hash FILE.jac
jac fmt FILE.jac
jac diff FILE_A.jac FILE_B.jac
jac diff STORE_A STORE_B
jac infer enumerate MODEL.jac
jac infer lw MODEL.jac --seed 42 --samples 100000
jac replay TRACE.jqd PROGRAM.jqd [--fork '1=(response 500 "down")']
jac test TESTS.jac [TESTS.jqd ...] [--exhaustive] [--cache-dir CACHE]
jac build FILE.jqd -o PROG
```

`.jac` is the user-facing surface carrier. Bootstrap `.jqd` remains fully
supported as the internal/debug syntax, quote notation, and kernel format of
record. `run`, `check`, `hash`, `fmt`, `diff`, `infer`, and `test` select
surface syntax by extension; native build, replay programs, the prelude, and
many internal fixtures continue to use `.jqd`.

Ordinary programs and demos need only a `.jac` source file. Do not hand-author
a `.jqd` twin unless a conformance test specifically needs to prove that both
carriers lower to the same kernel and hash. The paired files retained in the
corpus and selected demos are evidence fixtures, not an authoring requirement.

## Native compilation

`jacquard build` compiles a program and its reachable declarations to a
standalone binary whose output is byte-identical to `jacquard run` —
stdout, stderr, and exit codes, pinned by a differential harness in CI
(`scripts/native-diff.sh`). The full effect language compiles, including
capturing and multi-shot handlers, and code values compile since task
73 — quotes, splices, and the structural code ops. `eval` alone stays
on the interpreter tier (E1102 policy: dynamically loaded code runs
where the authority model lives).

```bash
export JACQUARD_PRELUDE=$PWD/prelude
export JACQUARD_RUNTIME=$PWD/runtime
jac build demos/tooling/word-count.jqd -o word-count
echo "some words some" | ./word-count --allow console
```

Requirements and knobs:

- A C toolchain: clang (any recent) or gcc. Tail calls are O(1) stack on
  every toolchain: musttail on clang and gcc 15+, a trampoline below
  them (the emitted C is identical either way).
- The binary parses `--allow EFFECT` (console, clock, fs, dist, infer so
  far), `--seed N` for the sampling grant, and refuses `--infer-cache`
  and `--dry-run` (interpreter tooling) with pointed errors.
- `JACQUARD_STACK_MB` sizes the program stack (default 1024): deep
  non-tail recursion is real C recursion in this backend.
- Compiled units cache under `.jacquard-native/`, keyed by content, so
  an unchanged program relinks without recompiling.
- Measured performance lives in `docs/benchmarks.md` — nine scenarios
  with interpreter, native (both toolchains), Python, and hand-C
  columns — with the claim boundaries in `docs/native-compilation.md`
  (reproduce with `scripts/native-bench.sh`).

## Demos

Start with these from the repo root after `dune build @all`. The same scripts
also work in an installed bundle without opam or Dune:

```bash
opam exec -- sh demos/case-studies/stormglass/run.sh
opam exec -- sh demos/case-studies/release-risk/run.sh
opam exec -- sh demos/basics/m1.sh
opam exec -- sh demos/inference/m3.sh
opam exec -- sh demos/worlds/agent-dream.sh
opam exec -- sh demos/worlds/preflight.sh
opam exec -- sh demos/tooling/repair.sh
```

What they show:

- `case-studies/stormglass/`: one checkout policy under simulated network and
  clock laws, exact incident forecasts, and Warp proofs over all 27 worlds.
- `case-studies/release-risk/`: one release policy under concrete and
  probabilistic telemetry, plus a Warp safety proof over all 18 worlds.
- `basics/m1.sh`: factorial, multi-shot choice, and gated eval.
- `inference/m3.sh`: one model under exact enumeration and likelihood weighting; same
  model hash, different inference handler.
- `inference/clarifying-question.sh`: an agent computes whether asking the user a
  question is worth the interruption (value of information).
- `worlds/agent-dream.sh`: one policy under scripted and probabilistic world handlers.
- `worlds/preflight.sh`: candidate agent plans scored under alternate worlds; the
  live policy still needs a Net grant after the dreams pass.
- `inference/ambiguity-pipeline.sh`: an extraction pipeline that keeps its uncertainty;
  the user's click becomes an `observe`.
- `tooling/showcase-warp-tests.sh`: Warp checks for the clarifying-question,
  dream-mode, and ambiguity demos.
- `tooling/repair.sh`: program repair as Bayesian inference; a bug report is an
  observation over computed single-edit patches, and the most likely patch
  prints as a one-line semantic diff.
- `worlds/m4-hostile.sh`: generated-looking code that reaches for `net`; signatures and
  manifests expose the authority.
- `worlds/escrow/run.sh`: product-shaped generated workflow with manifest, dry-run,
  Warp tests, fault exploration, replay, semantic diff, and approval by hash.

Demo paths are canonical within the categorized directories; there are no
flat compatibility aliases. The full catalog is in `demos/README.md`.

All public demo outputs are pinned by cram tests (recorded command-line
transcripts that fail on any drift), especially `test/cli/demos.t`,
`test/cli/hostile-demo.t`, `test/cli/escrow.t`, `test/cli/showcase.t`, and
`test/cli/repair.t`, `test/cli/preflight.t`, plus `test/cli/case-studies.t` for
the larger applications.

## Release Evidence

The release-candidate evidence pack lives in `docs/release/0.1/`.

To reproduce the release evidence from this checkout:

```bash
JACQUARD_RELEASE_REF=HEAD JACQUARD_RELEASE_BASE=738dc8e scripts/release/reproduce-0.1.sh
```

The script installs dependencies, builds, runs the full test suite, checks
formatting, runs public demos, runs gauntlet tests, records `jacquard --version`,
and writes generated evidence under `.scratch/release/0.1/`.

Key release docs:

- `docs/release/0.1/EVIDENCE.md`: what was built and what passed
- `docs/release/0.1/CLAIMS.md`: semantic claims mapped to tests and caveats
- `docs/release/0.1/REPRO.md`: fresh-clone reproduction steps
- `docs/release/0.1/FREEZE.md`: frozen version/hash/store/CLI surfaces
- `docs/release/0.1/GAUNTLET.md`: adversarial tests present and omitted
- `docs/release/0.1/LIMITS.md`: explicit non-goals and caveats
- `docs/release/0.1/DECISION.md`: release-candidate decision memo
- `docs/release/0.1/RELEASE-NOTES.md`: public RC contents and install command

## Repository Map

- `.github/`: CI, release evidence workflow, and PR template.
- `AGENTS.md`: operating notes for future coding agents.
- `bin/`: `jacquard` CLI entry point.
- `corpus/`: conformance corpus and golden outputs.
- `demos/`: runnable examples and product-shaped demos.
- `docs/`: design docs, tutorial, CI/CD, Warp, stdlib, errors, release evidence.
- `prelude/`: Jacquard standard library and effect declarations.
- `scripts/release/`: reproducible release evidence script.
- `spec/`: kernel AST and canonical serialization specs.
- `src/`: OCaml implementation.
- `test/`: Alcotest/QCheck suites plus cram CLI transcripts.
- `jacquard.opam`, `dune-project`: package and build metadata.

## Implementation Map

- `src/form.ml`, `src/meta.ml`, `src/span.ml`: uniform triple and metadata.
- `src/reader.ml`, `src/printer.ml`: bootstrap `.jqd` notation and formatter.
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
- `spec/jacquard-kernel-ast-m0.md`: kernel source-of-truth spec.
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
JACQUARD_RELEASE_REF=HEAD JACQUARD_RELEASE_BASE=738dc8e scripts/release/reproduce-0.1.sh
```

## CI/CD

GitHub Actions has two lanes:

- `CI / Development gate`: build, full tests, clean formatting, version smoke,
  and release-doc presence on PRs, `main`, and `release/**`.
- `Release Evidence / Reproduce 0.1 evidence`: release branches, `jacquard-core-*`
  tags, and manual dispatch; runs `scripts/release/reproduce-0.1.sh` and uploads
  transcripts.
- `Release Binaries`: `jacquard-core-*` tags and manual dispatch; builds
  Linux/macOS tarballs with `jacquard`, `jac`, and the packaged prelude.

See `docs/ci-cd.md` for branch protection recommendations.

## License

Jacquard is licensed under the GNU Affero General Public License, version 3 or
later. See [LICENSE](LICENSE).

Commercial licenses are available for organizations that need proprietary
derivative, hosted-service, redistribution, or expanded trademark terms. See
[COMMERCIAL-LICENSE.md](COMMERCIAL-LICENSE.md).

The Jacquard name and project identity are governed by
[TRADEMARKS.md](TRADEMARKS.md). The code license does not grant trademark
rights.

## Current Limits

Jacquard core is a research prototype, not a production platform. The `.jac`
surface is implemented and supported but remains an evolving v0 projection
onto the permanent 27-form kernel. Native AOT compilation and C-toolchain
optimization ship; a VM/JIT, concurrency, membrane enforcement, continuous
distributions, gradients, typed staging, language package management,
self-hosting, and formal soundness proofs do not. World grants remain coarse.
See `docs/release/0.1/LIMITS.md` for the exact RC1 boundary.

## Troubleshooting

- `opam: command not found`: install `opam` with asdf using `.tool-versions`, or
  install a compatible `opam` manually.
- Dune cannot find packages: run `eval "$(opam env)"` in this shell, then
  reinstall deps with `opam install --deps-only . --with-test --with-dev-setup
  --with-doc -y`.
- `jacquard` cannot find names from the prelude: set `JACQUARD_PRELUDE=$PWD/prelude` or
  run through Dune from the repo root.
- Formatting changed files: run `opam exec -- dune fmt`, inspect the diff, and
  commit the formatting changes if they are intended.
- Release reproduction writes generated evidence under `.scratch/release/0.1/`
  by default. Set `JACQUARD_RELEASE_OUT` to use another disposable output path.
