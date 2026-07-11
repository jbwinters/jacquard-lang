# Jacquard Core 0.1 RC1

Jacquard is a research language for running, reviewing, simulating, and
trusting programs written by models and reviewed by people.

This release candidate includes:

- the public `.jac` surface syntax and permanent `.jqd` kernel/debug carrier
- type-and-effect rows with explicit world capability grants
- deep, multi-shot algebraic effect handlers
- exact discrete enumeration and seeded likelihood weighting
- content-addressed definitions, semantic diff, and metadata-erased identity
- Warp testing, dry-run, record/replay, fault exploration, and semantic caching
- native binaries for Linux x86-64, macOS Intel, and macOS Apple Silicon

Install:

```sh
curl -fsSL https://raw.githubusercontent.com/jbwinters/jacquard-lang/jacquard-core-0.1-rc1/scripts/install.sh | sh
~/.local/bin/jac --version
~/.local/bin/jac run ~/.local/share/jacquard/demos/m1-fact.jac
```

The installer verifies the published SHA-256 checksum before extracting the
archive. `jac` is the short alias for `jacquard`.

This is a research prototype, not a production compiler. The explicit limits
and non-goals are documented in
[`LIMITS.md`](https://github.com/jbwinters/jacquard-lang/blob/main/docs/release/0.1/LIMITS.md),
and semantic claims are mapped to evidence in
[`CLAIMS.md`](https://github.com/jbwinters/jacquard-lang/blob/main/docs/release/0.1/CLAIMS.md).
