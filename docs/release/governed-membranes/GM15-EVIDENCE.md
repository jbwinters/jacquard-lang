# GM.15 hostile-world fault, replay, and native-parity evidence

Status: release-hardening evidence over exact integrated base
`bed0adb1615f3cdddf7771930bf6b2ea17b5c4bf`. GM.15 changes no production
module, public carrier, operation identity, handler, retry contract, fault seam,
or `ToolError` surface.

## Why this evidence exists

GM.12B proves reusable affine Workspace forwarding, GM.13B proves guarded
approval resumption, and GM.14B proves offline action reconciliation. Those
layers did not yet provide one hostile-world matrix showing that every
reachable governance/Workspace boundary follows its exact fail-stop or typed
error continuation without fabricating later interactions. They also did not
pin the accepted healthy replay shapes and reject trace drift field by field.

GM.15 adds that evidence without adding a production fault-injection API. The
closed Jacquard model, real interpreter host failures, strict replay fixture,
and closed native twin remain separate proof layers so one abstraction cannot
mask a defect in another.

## Closed 698-path matrix

`test/cli/governance-fault-laws.jqd` maps sampled integers `0..348` to the
reachable call sites in the released policy grid:

| branch | reachable sites |
|---|---:|
| live Allow | 12 |
| live Ask: Approved, Denied, or Escalate | 204 |
| live Block | 10 |
| dry Simulate | 60 |
| dry Block | 15 |
| stale Ask decisions | 48 |
| total | 349 |

For each selected site, `fault.all` chooses exactly two immutable
`gm15-fault-plan-v0` values: healthy and hostile. That selection completes
before execution enters the modeled Once boundaries. The exhaustive property
therefore covers the literal `349 * 2 = 698` paths without performing a
multi-shot operation inside an affine handler and without duplicating GM.12B's
50,000-case attenuation lane.

The matrix checks:

- the exact attempted interaction trace at `J` Judge, `E` Evaluated Audit, `S`
  simulation, `A` Approval, `K` Consented Audit, `D` raw driver, and `C`
  Completed Audit;
- `S-Err` as the frozen typed `Result Err`, continuing to `A` and the normal
  decision suffix for live Ask or to simulation-failed `C` for dry Simulate;
- fail-stop/non-resumption only for selected J/E/A/K/D/C failures;
- exact successful Evaluated, Consented, and Completed counts plus separate
  at-most-one raw-driver and simulator-attempt counts;
- at most one raw action, and a raw action only after successful evaluation;
- Consented for exact Approved, Denied, and Escalate decisions, before any
  Approved raw action; Stale has no Consented, and Denied, Escalate, and Stale
  perform no raw action;
- no fabricated completion after a raw-driver or completion-write failure;
  a dry-Block C failure follows zero action attempts, while live and dry
  Simulate C failures follow one D or S attempt respectively; and
- the released live/dry verdict partition for the canonical risk/confidence
  cells.

The separate literal case pins `12 + 204 + 10 + 60 + 15 + 48 = 349` and
`349 * 2 = 698`, preventing a changed generator from silently redefining the
claimed cardinality.

## Real interpreter failures

`test/test_governance_faults.ml` reuses the released GM.11 live Workspace
membrane and its real root-handler context unchanged. It injects actual
`Runtime_err.Io` values only at interpreter host boundaries:

- root Judge `assess`;
- root `governance-approval.ask`;
- Audit `Evaluated`;
- Audit `Consented`;
- raw `Fs.read`;
- Audit `Completed` after direct Allow; and
- Audit `Completed` after Approved consent.

Every case normalizes actual host attempts to J/E/A/K/D/C and compares the
entire exact prefix, including the failed-site attempt and absence of later
interactions. It also pins Audit/raw-action counts. A raw driver failure records
one attempted action but no Completed event; the live Completed failures occur
after exactly one raw action and are not presented as rollback. This layer is
interpreter-only because these are OCaml host failures, not closed language
effects. There is no pure-simulator `Runtime_err` seam: simulator failure is
the typed result covered by the closed matrix.

## Secret evidence factoring

The closed matrix and replay fixture use structural, payload-free labels. Their
not containing a private marker would be vacuous and is not claimed as a new
redaction proof. GM.15 instead reuses GM.11's non-vacuous driver evidence,
which performs the registered `Secret.read` and `Secret.expose` operations and
asserts that the fixed secret bytes do not enter review or Audit artifacts.

## Strict replay

`corpus/governance/gm15-healthy-traces-v0.tsv` freezes eight payload-free event
shapes: live Allow, Approved, Denied, Escalate, Stale, Block, dry Simulate, and
dry Block. Replay consumes site, operation, subject, and result in order.

The compiled replay case accepts all eight exact fixtures and refuses missing,
extra, reordered, wrong-operation, wrong-request, wrong-proposal, and
wrong-result streams. Each mutation occurs before `D`, and the assertion pins
zero raw work on refusal. Replay is evidence validation only; it does not
schedule, retry, or execute a provider operation.

## Closed native parity

`g41-governance-fault-plan.jqd` is deliberately closed. A fresh Once handler
receives an immutable failure-site argument and emits canonical `J/E/D/C`
prefixes for healthy, pre-action, action-boundary, and completion-boundary
runs. Its modeled fail-stop sites are J/E/D/C; it makes no simulator-error
claim. A failed clause does not resume into later work. The existing differential
gauntlet compares interpreter/native bytes and exit status.

The native twin does not claim native parity for OCaml `Runtime_err`, filesystem
descriptors, approval queues, or provider faults. Those remain host contracts;
only closed in-language control behavior is compared across engines.

## Claim boundary

GM.15 proves fail-stop J/E/A/K/D/C prefix behavior and typed S-Err continuation
for the frozen model, real failures at the listed interpreter boundaries,
strict acceptance of eight healthy traces, adversarial drift refusal before raw
work, and closed native handler parity.

It does not add automatic retries, compensation, rollback, provider receipt
authentication, a production chaos API, a new error taxonomy, new language
syntax, or broader native host support. A failed completion write still leaves
an honest recovery gap governed by GM.14B; it does not mean the action did not
happen. External freshness and publisher/provider trust remain outside this
evidence.

## Reproduction

```sh
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp"
export TMPDIR="$PWD/.scratch/tmp"
opam exec -- dune build --root "$PWD" @all
opam exec -- dune runtest --root "$PWD" --force
opam exec -- dune build --root "$PWD" @fmt
opam exec -- dune build --root "$PWD" @doc
scripts/release/reproduce-0.1.sh
sha256sum -c docs/release/governed-membranes/GM15-MANIFEST.sha256
```

The successor inventory is 783 compiled Alcotest/QCheck cases, 45 cram
transcripts, and 27 documentation examples across 8 documents.
