# Known Limits, No Hype

This file describes the actual Jacquard Core 0.1 RC1 boundary. It distinguishes
features that shipped from adjacent designs and future work.

RC2 and RC3 retain this semantic boundary. RC2 repaired binary-demo packaging;
RC3 clarifies user-program/output licensing and includes the native C runtime
in binary distributions.

## Research Prototype, Not A Production Platform

RC1 has a public parser, checker, CPS interpreter, native AOT compiler, content
store, standard library, Warp test runner, release binaries, and reproducible
evidence. It is still a research prototype. There is no stability history,
formal security audit, production operations record, or compatibility promise
beyond the versioned surfaces in `FREEZE.md`.

## Surface Syntax Is Implemented But Not Frozen

Public `.jac` supports declarations, signatures, functions, matches, handlers,
quotes, blocks, `if`/`else`, list literals, and pipelines. `run`, `check`,
`hash`, `fmt`, `diff`, `infer`, and `test` select it by extension. It lowers to
the same 27-form kernel as bootstrap `.jqd`; it is not a second semantics.

The grammar remains an evolving v0 surface. Native `build`, replay programs,
the prelude, and many internal fixtures still use `.jqd`, which remains a
permanent kernel/debug carrier rather than a deprecated syntax.

## Native AOT Is Real, But Not A VM Or Production Runtime

`jacquard build` emits C, links the Jacquard runtime, specializes reachable
definitions, caches compiled units by content identity, and uses clang or gcc
optimization. CI checks native/interpreter byte parity under both compilers,
ASAN/UBSAN behavior, leaks, and seeded differential fuzzing. Capturing and
multi-shot handlers, discrete inference, and structural Code operations are in
the tested native set.

The boundaries are explicit:

- native build currently consumes the `.jqd` carrier
- dynamic `eval` is interpreter-only and native build refuses it with E1102
- `--dry-run` and `--infer-cache` are interpreter tooling, not compiled-program
  features
- there is no VM, JIT, dynamic linker for newly evaluated code, or production
  runtime support policy
- the published benchmarks apply only to their named programs and machine;
  the project's own near-C gate remains withdrawn because the sort benchmark
  misses its threshold

See `docs/native-compilation.md` and `docs/benchmarks.md` for the measured
boundary rather than inferring one from the existence of native binaries.

## Released Binaries Are Not Language Package Management

RC1 publishes checksum-verified Linux x86-64, macOS Intel, and macOS Apple
Silicon archives plus a direct installer. That is application distribution.
Jacquard does not yet have a language package manager, dependency solver,
registry protocol, lockfile, or package signing/trust model. Other hosts must
build from source.

## Probability Is Finite And Discrete

Exact enumeration and seeded likelihood weighting operate over finite discrete
support. There are no continuous distributions, gradients, autodiff bridge,
variational inference, or production-scale probabilistic optimizer. Exhaustive
enumeration and `fault.all` retain their inherent branch-count cost.

## Staging Is Untyped At Eval

Quote/unquote and capability-gated eval exist. Typed staging and macro
expansion do not. Eval validates and checks constructed code, but its result
type is a dynamic boundary. Eval runs against root grants rather than an
interposed local handler stack.

## No Concurrency Or Effect-Membrane Enforcement

The shipped evaluator and native runtime are single-threaded. There are no
tasks, schedulers, channels, parallel handlers, structured concurrency, or
data-race guarantees. Effect-taxonomy, concurrency, and membrane documents are
design work until implementation and evidence land; they must not be described
as RC1 behavior.

## No Self-Hosting Or Formal Soundness Proof

Jacquard is implemented in OCaml and is not self-hosting. The row checker,
handlers, hashing, and capability boundaries have extensive adversarial tests,
but there is no machine-checked proof of row soundness, handler semantics, or
capability noninterference.

## World Authority Is Coarse

`--allow fs` and `--allow net` grant whole effects. Library handlers such as
`fs.read-only` can interpose within a handled region, but RC1 does not provide
path-scoped grants, host allowlists, per-object capabilities, quotas, or
region-level membrane enforcement. The runtime grant is the sandbox boundary.

## Direct Hash Refs In Code Remain A Review Risk

Quoted eval payloads may contain resolved refs such as `(ref #... op)`. If both
`eval` and the target world grant are installed, that code can run. Granting
`eval` alone does not imply `net`, `fs`, or another world grant, but direct refs
remain a policy concern for review of generated Code.

## Top-Level Rows Are Closed

Effectful top-level bodies are rejected with E0815. RC1 does not implicitly
eta-expand them into thunks. A stored named computation passed where an open row
is required may need an explicit thunk such as `fn () -> model()`.

## Handler Clause Scope Has A Deliberate Edge

An operation-clause body runs at the handler frame, outside the handler's own
handled region; resuming re-enters the deep handled continuation. Effects thrown
from a clause therefore do not behave as though they originated at the perform
site. This is documented and tested, but handler authors must design retry and
failure placement with that scope rule in mind.

## Data And Identity Have Fixed Low-Level Choices

Integers are wrapping native 63-bit values. Text is UTF-8 with no Unicode
normalization and codepoint rather than grapheme semantics. HASH_V0 is SHA-256
over the current canonical serialization. These are documented version choices,
not claims of portability across future identity versions.
