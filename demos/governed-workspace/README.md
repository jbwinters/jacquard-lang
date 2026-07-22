# Governed Workspace flagship

This demo keeps one small deployment agent unchanged while four deterministic
worlds interpret its released `Workspace` requests. The agent reads a manifest,
fetches an artifact, writes generated configuration, and requests deployment
with the same typed `Workspace.fetch(Request)` API. It never imports `Fs`,
`Net`, `Secret`, governance, approval, or audit authority.

The launcher shows:

- a grant-free dry run whose closed simulators perform all four requests and
  whose inferred row is pure;
- a nested live membrane where an inner `Allow` forwards the exact call to a
  stricter outer `Block`, plus a policy-only change that permits the same agent
  through the real `workspace.live-layer` raw-driver leaf. The host reports
  exact `Fs`, `Net`, `Secret`, and driver-order counters, and derives both
  policy IDs beside the unchanged agent ID and outcomes;
- a proposal-only preflight through the real `Governance_approval_bridge` and
  durable `Governance_approval_queue`. The queue consumes a `Denied` decision
  bound to the canonical deployment proposal before live authority is entered,
  so every raw counter remains zero;
- a bounded agent-specific `fault.all` world. It chooses all four immutable
  fault bits before installing the Workspace Once handler, then runs the exact
  unchanged agent across all 16 assignments. The resulting facade-call
  prefixes prove that failures stop later calls, earlier failures never reach
  deployment, and deployment occurs at most once; and
- a reconstructed v2 audit chain whose independently supplied head verifies.

The existing GM.15 349-site/698-path lane remains supporting infrastructure
evidence; it is not presented as the agent's fourth world. Fault-world counters
describe Workspace facade prefixes, not raw live-driver calls. Only the live
host rows make raw `Fs`/`Net`/`Secret` claims. Its exact request check occurs at
the deployment Net/provider boundary after earlier live file, artifact, and
secret work; request drift proves zero deployment-provider calls, not zero
Secret access. Strict refusal and queue denial separately demonstrate zero
Secret access.

`run.sh` is intentionally checkout-only developer evidence. The queue bridge
and GM.15 fixture are bounded test/review seams, not new CLI or language
surface. From a fresh clone after the README setup has created the local switch:

```sh
eval "$(opam env)"
sh demos/governed-workspace/run.sh
```

The script builds its checkout evidence host and CLI dependencies. `agent.jac`
is the readable public application. `story.jac` contains deterministic
interpreters and the proposal-only approval request, `tests.jac` contains
sampled and exhaustive Warp laws, and the three `corpus/governance/gm18-*.jqd`
files are audit-chain data fixtures—not hand-maintained program twins.
