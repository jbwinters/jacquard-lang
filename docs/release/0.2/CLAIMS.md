# Jacquard Core 0.2 Claims

Status: bounded public claim matrix for the 0.2 distribution.

Every positive statement below is paired with its nearest important limit.
The detailed predecessor and successor evidence packs remain authoritative for
their individual contracts.

| Public claim | Executable or frozen evidence | Adjacent boundary |
| --- | --- | --- |
| Public `.jac` programs parse, format, lower to the permanent 27-form kernel, and can be checked, run, tested, inferred, or built. | surface corpus twins and goldens; parser/formatter/lowering suites; CLI crams; `../surface-syntax/` and `../dx-jac-export/` | `.jac` is an evolving v0 projection, not a frozen future grammar. `.jqd` remains the kernel/debug carrier. |
| Canonical `HASH_V0` identity erases non-identity metadata and ordinary local or term renames. | canon/hash/store suites, corpus goldens, surface twin parity | Hash equality is structural identity under the frozen serialization rules, not arbitrary behavioral equivalence or proof of trustworthy source. |
| Type-and-effect rows expose transitive effects, and world effects require explicit CLI grants unless handled. | checker, manifest, handler, prelude, hostile-demo, and native-parity suites | Grants are language-runtime controls, not an OS sandbox; a compromised host or runtime remains trusted. |
| `multi` handlers may resume repeatedly; `once` handlers receive affine resumptions with static and runtime reuse protection. | handler and gauntlet suites; `../effect-linearity/` | The analysis is deliberately bounded and conservative; runtime E0906 remains a backstop. |
| Finite discrete `Dist` models support exact enumeration and likelihood weighting as handlers. | inference suites and demos | Continuous distributions, gradients, and general probabilistic termination guarantees do not ship. |
| Warp supports hermetic, exhaustive or sampled properties, caching, replay, fault exploration, and relational variation lanes. | Warp/property/cache/fault/replay suites; `../relational-warp/` | Exhaustiveness applies only to declared finite supports and bounded schedules; cache identity is not a proof of semantic equivalence. |
| Interpreted scopes provide opaque Tasks, cooperative cancellation, fail-fast language scopes, deterministic scheduling, strict replay, bounded exhaustive scheduling, and scoped typed Channels. | concurrency suites and crams; SC.17; `demos/concurrency/run.sh` | Scheduling and Channels are interpreter-only; cancellation is cooperative and lifetime checks are dynamic. Native C4 concurrency, preemption, select, actors, and real async host I/O do not ship. |
| Audit has canonical entry/hash-chain carriers; Secret is opaque until explicit exposure; Approval binds decisions to exact proposals and rejects stale decisions. | effect-taxonomy suites, crams, and retained manifests | Audit records can faithfully preserve false inputs; Secret is not whole-program taint tracking; host identity, vault, and reviewer authentication stay outside the language proof. |
| Workspace v0 composes typed governed facades, dry/live boundaries, approvals, audit ordering, queue/recovery logic, deterministic review facts, and conservative policy joins. | governed-membranes suites, crams, 50,000-case GM.12B proof, viewer checks, `demos/governed-workspace/run.sh`, and `demos/case-studies/night-shift/run.sh` | This is an evidence-backed research reference implementation, not a production policy engine, sandbox, identity provider, or proof against a malicious host. Approximate judgment remains model evidence, not ground truth. |
| Native AOT accepts `.jac` and `.jqd`, emits C, and is compared with the interpreter under Clang and GCC. | compiler, exporter, runtime memory, differential, leak, and seeded fuzz lanes | Supported native effects are a documented subset; native scheduling and Channels do not ship. Tests are strong finite evidence, not a compiler-correctness proof. |
| Checksum-verified archives install on Linux x86-64, macOS Intel, and macOS Apple Silicon without OCaml or Dune. | packaging workflow, archive smoke, installer smoke, checksum rejection | Other platforms require source development; the installer does not provide automatic updates, signatures beyond GitHub/tag provenance and SHA-256, or a package manager. |

No claim is made about results from human readability participants. The
readability materials define a protocol and synthetic reproduction evidence;
no completed human study is part of 0.2.
