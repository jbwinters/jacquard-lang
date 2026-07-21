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
  exact `Fs`, `Net`, `Secret`, and driver-order counters;
- a proposal-only preflight through the real `Governance_approval_bridge` and
  durable `Governance_approval_queue`. The queue consumes a `Denied` decision
  bound to the canonical deployment proposal before live authority is entered,
  so every raw counter remains zero;
- the existing GM.15 Warp fixture executing all 349 hostile sites and 698
  typed-error/fail-stop paths; and
- a reconstructed v2 audit chain whose independently supplied head verifies.

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
sampled and exhaustive Warp laws, and the three `.jqd` files are audit-chain
evidence fixtures—not hand-maintained program twins.
