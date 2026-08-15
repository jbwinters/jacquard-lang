# Jacquard Core 0.2 Limits

Jacquard 0.2 is a research prototype. These limits are part of the release,
not a future-work appendix to omit from public descriptions.

## Language and Compatibility

- The 27-form kernel, `.jqd` carrier, `HASH_V0`, native 63-bit wrapping
  integers, UTF-8-without-normalization rule, splitmix64-derived seeded PRNG,
  and uncurried final-call convention remain as documented.
- Public `.jac` is implemented and supported, but is still an evolving v0
  projection. 0.2 does not promise that every future surface program will
  parse unchanged.
- Records, broader macros beyond quote/unquote/gated eval, typed staging,
  continuous distributions, gradients, language package management,
  self-hosting, and ownership/borrowing do not ship.
- There is no formal type-soundness, handler-soundness, serialization, or
  compiler-correctness proof.

## Runtime and Native Execution

- Language grants constrain the Jacquard runtime; they do not isolate hostile
  native code, replace filesystem/container permissions, or defend against a
  compromised runtime, compiler, operating system, or dependency.
- Native AOT implements a documented subset. Dynamic `Eval`, interpreted Task
  scheduling, and typed Channels are not native execution features.
- Parallel hints remain sequential. Structured concurrency is cooperatively
  scheduled in the interpreter; cancellation is not preemptive, cleanup uses
  explicit brackets, and ownership/lifetime enforcement is dynamic.
- There is no VM/JIT, shared-memory model, select/timeouts, actors,
  supervision tree, host scheduler, or real asynchronous host I/O runtime.

## Probability, Warp, and Evidence

- Exact inference is finite and discrete. Likelihood weighting is approximate
  sampling evidence; neither mode proves a model is well specified.
- Exhaustive Warp and schedule results are exhaustive only within their
  declared finite support and bounds.
- Hashes establish byte or canonical-structure identities under documented
  encodings. They do not establish truth, authorship, intent, safety, or
  behavioral equivalence.
- The test inventory, fuzz seeds, model-checking bounds, and 50,000-case grid
  are finite evidence. Passing them does not eliminate untested defects.
- The readability benchmark has a protocol and synthetic harness evidence but
  no human-participant result released here.

## Governance, Approval, Audit, and Secrets

- Workspace v0 and the governance viewer are research reference surfaces, not
  a production authorization system or security boundary.
- Trusted host code owns persistence, locking, identity/authentication,
  external-state freshness, I/O, provider integration, and final action
  execution. The language cannot prove that a malicious host obeyed a verdict.
- Approval decisions bind exact proposal artifacts and reject stale content;
  they do not authenticate the human without a trusted host identity layer.
- Audit chains detect mutation under their hash and publication assumptions;
  they can preserve false statements faithfully and are not transparency logs
  or independently witnessed ledgers.
- Secret values have an explicit opaque/exposure boundary, but Jacquard does
  not provide whole-program taint tracking, memory erasure, side-channel
  resistance, or a production vault.
- Approximate Judge results and review-fact projections are evidence for a
  policy decision, not objective truth.

## Distribution

- Published binaries target only Linux x86-64, macOS x86-64, and macOS arm64.
  Other systems require the source toolchain.
- Downloads are checked with SHA-256. The release does not ship a language
  package manager, automatic update channel, reproducible-build guarantee
  across arbitrary hosts, or a separate code-signing/notarization system.
- The browser governance viewer remains source-checkout-only and offline; it
  is not deployed as a supported hosted product.
