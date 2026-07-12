# Jacquard Core 0.1 RC2

Jacquard is a research language for running, reviewing, simulating, and
trusting programs written by models and reviewed by people.

RC2 corrects an RC1 packaging defect: bundled narrative launchers no longer
assume Dune or a source checkout, and escrow now has a self-contained launcher.
The language semantics and `0.1.0` CLI version are unchanged.

This release candidate includes:

- the public `.jac` surface syntax and permanent `.jqd` kernel/debug carrier
- type-and-effect rows with explicit world capability grants
- deep, multi-shot algebraic effect handlers
- exact discrete enumeration and seeded likelihood weighting
- content-addressed definitions, semantic diff, and metadata-erased identity
- Warp testing, dry-run, record/replay, fault exploration, and semantic caching
- organized runnable demos, including release-risk and Stormglass case studies
  with sampled and exhaustive Warp evidence
- native binaries for Linux x86-64, macOS Intel, and macOS Apple Silicon
- installed demo launchers that run without OCaml, opam, or Dune, including a
  self-contained executable-escrow narrative

Install:

```sh
curl -fsSL https://raw.githubusercontent.com/jbwinters/jacquard-lang/jacquard-core-0.1-rc2/scripts/install.sh | sh
~/.local/bin/jac --version
~/.local/bin/jac run ~/.local/share/jacquard/demos/basics/m1-fact.jac
```

The installer verifies the published SHA-256 checksum before extracting the
archive. `jac` is the short alias for `jacquard`.

This is a research prototype, not a production compiler. The explicit limits
and non-goals are documented in
[`LIMITS.md`](https://github.com/jbwinters/jacquard-lang/blob/main/docs/release/0.1/LIMITS.md),
and semantic claims are mapped to evidence in
[`CLAIMS.md`](https://github.com/jbwinters/jacquard-lang/blob/main/docs/release/0.1/CLAIMS.md).
