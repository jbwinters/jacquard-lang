# Jacquard Core 0.2.0

Jacquard 0.2.0 is the first integrated release of the public `.jac` authoring
surface and the successor research systems built over the 27-form kernel.

Highlights:

- readable `.jac` source with deterministic formatting, kernel lowering,
  direct native build, and bootstrap export;
- explicit effect rows and runtime grants, deep multi-shot handlers, and
  affine `once` resumptions;
- finite discrete inference, Warp properties, replay, fault exploration, and
  relational schedule/Secret/grant variation;
- interpreter structured concurrency with scoped Tasks, cooperative
  cancellation, deterministic and exhaustive scheduling, strict replay, and
  scoped typed Channels;
- canonical Audit chains, opaque Secret handling, proposal-bound Approval,
  and a typed Workspace v0 governance reference implementation;
- native AOT differential, memory, leak, and seeded fuzz evidence under both
  Clang and GCC;
- checksum-verified archives for Linux x86-64, macOS Intel, and macOS Apple
  Silicon, including the prelude, demos, and native runtime.

Install the final release:

```sh
curl -fsSL https://raw.githubusercontent.com/jbwinters/jacquard-lang/jacquard-core-0.2.0/scripts/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
jac --version
jac run "$HOME/.local/share/jacquard/demos/basics/m1-fact.jac"
```

For RC verification before final promotion:

```sh
curl -fsSL https://raw.githubusercontent.com/jbwinters/jacquard-lang/jacquard-core-0.2.0-rc1/scripts/install.sh \
  | JACQUARD_INSTALL_VERSION=jacquard-core-0.2.0-rc1 sh
```

Jacquard remains a research prototype. Language grants are not an OS sandbox;
structured concurrency and Channels are interpreter-only; probability is
finite and discrete; Workspace governance is not a production authorization
system; the public `.jac` projection remains evolving v0 syntax; and no human
readability result is claimed. Read [the bounded claims](CLAIMS.md), [full
limits](LIMITS.md), and [reproduction procedure](REPRO.md) before relying on a
feature claim.
