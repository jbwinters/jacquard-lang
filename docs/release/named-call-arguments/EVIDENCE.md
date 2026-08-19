# SX.23 Named Call Arguments Evidence

Status: successor evidence over Task 171's merged labeled-pattern base
`0509eddd56d88ec492f67ae45c66a332a606bbcb`.

## Current Inventory

- Alcotest/QCheck cases: `877`
- Cram transcript files: `59`
- Doctest examples: `28` across 8 documents

SX.23 adds six compiled semantic cases in
[`test_surface_named_calls.ml`](../../../test/test_surface_named_calls.ml) and
two D76 decision-mutation cases in
[`test_surface_laws.ml`](../../../test/test_surface_laws.ml), plus one CLI transcript in
[`named-args.t`](../../../test/cli/named-args.t). No doctest cohort is added.

## Evidence Matrix

| boundary | evidence |
|---|---|
| parse, recovery, trivia, width, and formatter idempotence | `parse print quote recovery` compiled case; `jac fmt` CLI transcript |
| direct terms and same-SCC calls | `direct hashes and source order` compiled case |
| constructors and operations, including positional prefixes | `constructors and operations` compiled case; `supported.jac` CLI fixture |
| exact source-order evaluation and native parity | effectful reordered CLI program prints `RL(1, 2)` identically under `jac run` and a clang-built binary |
| positional kernel and hash parity | declaration-order and explicit-let hash twins in the compiled suite; `.jac`/exported `.jqd` hash comparison in the CLI transcript |
| fail-closed diagnostics and spans | `fail-closed diagnostics` compiled case; E0309-E0314 and E1238 CLI fixtures |
| persistent identity-bound ABI | `store identity reopen conflict` proves installation, reopen, public rename, binder rename, E0612 conflict, and transactional preservation |
| checker review guidance and editor recovery | `checker warnings and recovery names` proves W1206/W1207 positive and negative shapes plus same-file recovery ABI visibility |
| bootstrap boundary | `jac export` produces runnable positional `.jqd`; named syntax in quotes is E1238 |

## Required Gates

Run from the repository root with the repository-local opam environment and a
repository-local `TMPDIR`:

```sh
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp"
export TMPDIR="$PWD/.scratch/tmp"
opam exec -- dune build @all
opam exec -- dune runtest
opam exec -- dune fmt
git diff --exit-code
opam exec -- dune build @doc
```

The focused CLI transcript is:

```sh
opam exec -- dune runtest test/cli/named-args.t --force
```

The ordinary `@all` gate also runs the existing readability-protocol and
schedule checks. Their passing status is regression evidence only. No SX.23
participant data, readability score, blinded rescore, or study conclusion is
claimed or invented.

## Limits

This is bounded executable evidence, not a proof over every surface tree, a
human readability result, or a new runtime semantics. Named local/HOF calls,
defaults, puns, partial application, record types/accessors, a named `.jqd`
carrier, exported companion ABI, and companion-aware kernel diff are outside
the shipped boundary.
