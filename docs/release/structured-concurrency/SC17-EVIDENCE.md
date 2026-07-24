# SC.17 Transitive Cancellation Correction

Status: safety correction over exact predecessor
`0783845027a392fe59087534cd6b147ccff2b123`, July 2026.

SC.17 corrects the implementation behind the existing structured-concurrency
contract. It does not add a feature, widen C0-C3, change public syntax, change
the 27-form kernel, or change any `HASH_V0` identity.

## Context

The published contract says a structured scope cannot leave detached work
behind. The round-robin scheduler nevertheless had one path that violated that
rule: cancelling a task suspended while its `async.scope` was open
terminalized the task but did not cancel the nested scheduler run it owned.
The nested run stayed in the shared FIFO. Its descendants could receive later
scheduler decisions and could invoke a granted world-effect callback after
their ancestor was already `Cancelled`.

The same orphaning was reachable when fail-fast policy cancelled a sibling
that was waiting on an open nested scope. The original SC.16 manifest and
checker are retained byte-for-byte as historical attestation anchors; this
successor pack reconstructs their publication commit and records the
correction instead of rewriting those anchors.

SC.17 necessarily changes two integration files also hashed by the later
GM.21 release pack: this evidence document and the shared cram dependency
list. The GM.21 manifest and checker are therefore retained byte-for-byte too.
SC.17 reconstructs their exact publication tree before checking its own
successor overlay; it does not manufacture an unrelated governance milestone.

## Corrected invariant

Cancellation is transitive over every nested run owned by the cancelled task:

1. A task that is waiting on `async.scope` owns that nested run, not merely the
   continuation that will receive its result.
2. When the owner becomes `Cancelled`, the scheduler cancels the nested run
   and all of its descendant runs depth-first.
3. Every nonterminal body and child task in those runs reaches `Cancelled`,
   and every queued occurrence is removed, before the enclosing scope may
   complete.
4. No descendant receives another scheduler decision or invokes a routed
   world callback after ancestor cancellation is delivered.
5. Direct `async.cancel` and fail-fast sibling cancellation obey the same
   rule.

This remains cooperative cancellation. Pure code that is currently executing
without reaching await, yield, or a routed effect is not preempted. SC.17 also
does not add automatic external-resource finalizers; acquire/release handlers
remain responsible for those resources.

## Implementation and regression evidence

`src/round_robin.ml` now tracks whether cancellation of a nested run has
started. Terminal observation of `Cancelled` discovers every scope run owned
by that task, drains descendant runs depth-first, requests and immediately
delivers cancellation to each nonterminal body and child, removes them from
the shared FIFO, and records their terminal observations before finalization.
The idempotence guard prevents recursive observation from draining a run
twice.

`test/test_cancellation.ml` pins both previously unsafe routes with real
evaluator states:

- Direct cancellation opens one nested scope, queues a descendant whose first
  step would perform a granted Console operation, and cancels the owning task
  before that step is chosen. Record and strict replay are byte-identical, the
  Console callback remains untouched, the descendant receives no scheduler
  choice, and both nested tasks are terminal.
- Fail-fast cancellation opens two nested levels beneath a sibling, queues the
  deepest descendant whose first step would perform a granted Console
  operation, and fails another sibling before that step is chosen. The callback
  remains untouched, the descendant receives no scheduler choice, and both
  nested scope bodies are terminal.

Both checks live inside the existing cancellation case, so the successor
inventory remains exactly 826 compiled Alcotest/QCheck cases, 51 recursive
cram transcript files, and 27 named doctest examples across 8 documents.

Warp's native driver semantics are deliberately part of its explicit cache
version because they are not represented by a Jacquard definition hash.
SC.17 therefore advances that version from `warp-v1` to `warp-v2`. A compiled
regression writes and successfully reads a persistent `warp-v1` entry, then
proves the corrected driver misses it under the `warp-v2` key instead of
reusing the pre-correction verdict.

## Verification

The SC.17 checker pins the unchanged historical SC.16 and GM.21 manifests and
checkers, strictly verifies every SC.17 overlay file, and compares the overlay
inventory with the exact predecessor when full Git history is available:

```sh
scripts/release/check-sc17-manifest.sh
```

With full Git history, it also archives publication commit
`81c14506e0d099dabe04a40b00c1d4fc45b42d47` under repository-local scratch
space and runs the historical SC checker inside that archive. It separately
archives GM.21 publication commit
`0783845027a392fe59087534cd6b147ccff2b123` and runs that tree's GM.21 checker.
In a source archive or Dune sandbox, it verifies all four pinned historical
attestation anchors and every SC.17 entry, then states that historical
reconstruction was unavailable. That reduced mode does not claim to prove
unlisted predecessor bytes.

The implementation gate is:

```sh
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp"
export TMPDIR="$PWD/.scratch/tmp"
opam exec -- dune build @all
opam exec -- dune runtest --force
opam exec -- dune fmt
git -c core.whitespace=trailing-space,space-before-tab diff --check
```

The release-facing gate additionally runs
`scripts/release/reproduce-0.1.sh`. Successful final results are recorded on
the pull request for the exact reviewed commit.

## Preserved boundaries

- The original [`MANIFEST.sha256`](MANIFEST.sha256) and
  `scripts/release/check-structured-concurrency-manifest.sh` are unchanged.
- The GM.21 manifest and checker are unchanged and are verified in their exact
  publication tree.
- C0-C3 and D46-D50 retain their published meanings.
- C4 host asynchronous I/O, actors, and supervision remain unclaimed.
- Native root Async scheduling remains unsupported.
- Task scoping remains dynamically enforced, and cancellation remains
  cooperative at the three published boundary classes.
- Public `.jac`/`.jqd` syntax, diagnostics, serialization, and definition
  identities are unchanged. Scheduler behavior and resulting traces are
  intentionally corrected for transitive nested-scope cancellation.
