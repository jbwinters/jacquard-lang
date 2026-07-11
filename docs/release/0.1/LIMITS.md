# Known Limits, No Hype

## Not A Production Compiler

Jacquard core 0.1 is a research prototype. It has a real parser, checker, evaluator,
store, CLI, and tests, but it is not a production compiler or runtime.

## Surface Syntax Is Not Frozen

The `.jac` authoring syntax is implemented as a tested projection onto the
kernel, while bootstrap `.jqd` remains the internal/debug format of record.
The evidence does not claim that the surface grammar is frozen or that it has
independent semantics.

## Native Compiler Is Not A Production Runtime

The CPS tree-walker remains available, and the native compiler has interpreter
parity coverage for pure code and a broad tested effect subset. It is not a VM
or production runtime: unsupported grants and slow paths are documented in
`docs/native-compilation.md` and pinned by the native cram suites.

## No Continuous Distributions Or Gradients

Dist is finite/discrete. Enumeration and likelihood weighting over discrete
support are in scope; gradients and continuous distributions are not.

## No Typed Staging

Quote/unquote and gated eval exist. Typed staging does not. Eval result typing
is a dynamic boundary.

## No Package Management

The content-addressed store exists, but package distribution and dependency
management are out of scope.

## No Self-Hosting

Jacquard is implemented in OCaml. Self-hosting is not a 0.1 claim.

## No Formal Proof Of Row Soundness

The row checker has extensive tests, including higher-order and handler cases,
but there is no formal proof.

## Coarse World Authority

`--allow fs` grants the whole filesystem effect; `--allow net` grants the stub
network effect. Library interposition such as `fs.read-only` can attenuate
within a handled region, but 0.1 does not provide path-scoped or object-level
capabilities.

## Direct Hash Refs In Code

Current policy: quoted eval payloads may contain explicit resolved refs such as
`(ref #... op)`. If `eval` and the target world grant are both present, the code
can run. Granting `eval` alone does not install world handlers, so it does not
imply `net`/`fs`, but this remains a policy risk for generated Code review.

## Top-Level Closed-Row Eta-Expansion

Effectful top-level bodies are rejected with `E0815`. The release does not
support implicit eta-expansion to turn such bodies into thunks.

## Deep-Handler Clause Throw Caveat

Handler opclause bodies run at the handler frame, not at the original perform
site. Library code such as `net.try-fetch` is shaped to deliver retryable
failures at the call site. This is documented and tested, but it is a semantic
edge reviewers should know.

## Performance Status

The native backend has measured benchmark evidence in `docs/benchmarks.md`.
Those measurements are scoped to their named programs and environment; they do
not establish general production performance or erase the documented slow set.
