# CAP.0 Authority Requirements Decision

- Decision date: 2026-09-23
- Inputs: `jacquard-host-core-requirements-v1` (jacquard-host
  `docs/CORE-REQUIREMENTS.md`, host main `21da229`, delivered by host PR 8,
  merge `0075c80`) and its authority inventory (`docs/AUTHORITY.md`); the
  draft `docs/authority-attenuation.md` (PROPOSED, 2026-07-24/25); the shipped
  governance verifier (`src/governance_verify.ml`, `governance-verifier-v0`/`v1`).
- Consumer: CAP.1 (task 202), which this document makes implementation-ready.
- Release posture: post-0.2 research prototype. No OS-sandbox claim.

## 1. What The Host Evidence Says

The host built the serial HTTP trial slice (H0.1–H1.3) against Core's frozen
host contract and reported what it needed. For authority, the report is
explicit: the closed `once` operation registry plus Core's E1606 preflight
refusal was sufficient. The single outside action, `study.save-response`, was
refused before action on invalid input and never retried on unknown
completion. **No path, host, port, or database-row containment was needed or
claimed, and the host requests none from Core for this slice.** What it needs
is what the frozen contract already gives: exact identities, the E16xx
classification, and separate evidence schemas, all of which held.

Each resource class the task names, from the host's authority inventory
(`docs/AUTHORITY.md` at host `21da229`):

| requirement | host answer | reachable from Jacquard? |
|---|---|---|
| inbound bind/accept | loopback TCP only (`127.0.0.1`, `::1`, `localhost`); anything else refused at construction | no: host startup configuration |
| outbound connect | none of any kind | no |
| exact address/host/port | only the loopback bind above; no port requirement stated | no |
| filesystem roots and modes | the work directory, the Core prelude and store paths given at startup, the package's own sources, a temp directory for bounded stderr, an operator-named report path; no per-root modes stated | no: startup configuration |
| host-owned persistence | one SQLite file behind `study.save-response`, opened by the host at startup, one idempotent transaction, no retry on unknown completion | yes, only through that one closed-registry operation |
| secret namespaces | none beyond `JACQUARD_BIN`, `JACQUARD_PRELUDE`, `TMPDIR`; children inherit the parent environment with the last two overridden | no |
| refusal evidence | Core's E1606 preflight refusal before any request leaves the worker, plus the E16xx classification | yes: Core evidence, returned unchanged |
| nested policy | none: the host has no handler chain; every policy decision is inside Jacquard code or Core's checker | no |

Consequences for this decision:

- There is no positive external case for any resource refinement. The CAP.1
  grammar must therefore be justified by Core's own in-repository boundaries
  (the draft's `fleet.serve` narrowing `Net` to named hosts and the workspace
  facade narrowing `Fs` to a subtree) and kept to the smallest form those
  cases use.
- No port requirement and no per-root file mode was reported.
- The worker child inherits the full parent environment. That matters for
  `Secret` namespaces: a `Secret` grant's reach is the environment the worker
  was started with, so any `Secret` refinement is a name-prefix narrowing of
  what is already visible, never a containment of the environment itself.
  The v0 host protocol has no `secret` operation encoding
  (`docs/host-worker-v0.md`), so no host can exercise one today.

## 2. Decisions

The draft left three questions to the owner. Each is resolved here; the
reason is recorded so a later owner decision can overturn it deliberately.

### D-CAP0.1 `Net` has no ports in v0

The `Net` refinement is host-only: an exact host, or one leading `*.` label.
No requirement, host-side or in-repository, names a port, and ports would
double the grammar for one hypothetical use (registry mirrors). A port
refinement can be added later as an additive atom version without changing
the meaning of any host-only atom, because an atom without a port already
means "any port".

### D-CAP0.2 Attenuation refusals are audited inside a gate, with no new schema

An attenuating combinator is an ordinary handler: it has no proposal, call,
or policy identity and no sequence owner of its own, so it does not write
audit records by itself. A refusal is a typed, non-throwing E0820 result
(§4) that the caller sees and that appears in the run's diagnostics.

When the refusal happens inside a governed gate's action (the only place a
`with-sequence` owner, an `AuditSequence` token, and a call ID exist), the
gate's existing D69 records already cover it: the action returns without
performing the refused operation, and the gate's `Completed(version,
sequence, call-id, branch, outcome)` record carries an outcome summary whose
status is `attenuated` and whose detail names the refused atom and the
widest uncovered atom. The gate builds that summary with its caller-supplied
`Result ToolError a -> GovernanceOutcomeSummary`, so CAP.1 maps an E0820
refusal to a dedicated `ToolError` case that the stock summarizers render as
`attenuated`. No audit type gains a constructor, so no audit
identity changes. Outside a gate nothing is audited, exactly as for any other
non-gate refusal today. The reason is consistency with D69 (every executable
gate path has a pre-action record and a `Completed` record) without
inventing a second, gate-less audit stream.

Redaction: a `Secret` refinement is a `SecretRef` *name* prefix, which is
already public in proposals; it appears in the outcome detail verbatim.
Secret *values* never reach an attenuation record, because combinators judge
names only. The existing rule that an opaque Secret value is never rendered,
compared, or serialized (E0819) is unchanged.

### D-CAP0.3 The order is trusted Core code, exposed to the prelude (owner acknowledgment gates CAP.1)

**This departs from the draft's recommendation and from the task's wording
("the Jacquard prelude-ring order"); CAP.1 must not start on it without the
owner's explicit acknowledgment.** The alternative, if the owner prefers the
ring, is recorded below.

The containment order `a ⊑ b` is implemented once, in OCaml under `src/`,
beside the verifier that already compares authorities (`authority_equal` in
`src/governance_verify.ml`), and exposed to Jacquard as a trusted builtin
(`authority.covers?`) through the existing mechanism: a
`(quote (builtin-marker authority.covers?))` binding in
`prelude/04-builtins.jqd` wired by `Prelude.wire_builtins`, with a native
intrinsic like the other builtins. The attenuating combinators call it. The gate, the
additive `governance-verifier-v2`, and the prelude combinators therefore run
the same judgment. This departs from the draft's lean toward a prelude ring
for one reason: the draft's worry was a gate "trusting a judgment made
outside the language's own evidence discipline", but the verifier the gate
already trusts is Core OCaml, not host code. Putting the order in a prelude
ring while the verifier stays in OCaml would create two implementations of
one relation that could drift; one trusted implementation, exercised from
both sides and pinned by the same law suite, closes that gap. The host never
supplies or evaluates the order. The evidence concern the draft raised is met
the same way the verifier's own judgments are: the verdict, the compared
lists, and the widest uncovered atom are the evidence, and the law suite pins
the relation that produced them.

Alternative (prelude ring): implement `⊑` as Jacquard terms in a prelude ring
and have `governance-verifier-v2` evaluate them. That keeps the judgment
in-language, but requires the OCaml verifier to evaluate prelude code (it
does not today) and to trust the evaluator's result, and it still needs the
same law suite. It is viable, costs more, and is the owner's call.

## 3. The Frozen v0 Atom Grammar For CAP.1

| effect | refinement | containment `(e, p1) ⊑ (e, p2)` | top |
|---|---|---|---|
| `Net` | exact host, or `*.` followed by a domain | equal hosts; or `p2 = *.d` and `p1` is a strict subdomain of `d` (`*.example` covers `api.example` and `a.b.example`, not `example`: list both atoms to include the apex); or `p1 = *.d1`, `p2 = *.d2`, and `d1` is `d2` or under it | bare `Net` |
| `Fs` | canonical absolute path prefix, no globs, no `..` | `p2` is a path prefix of `p1` on component boundaries | bare `Fs` |
| `Secret` | `SecretRef` name prefix | `p2` is a prefix of `p1` | bare `Secret` |

- `(e, p) ⊑ (e)` for every refinement; atoms of different effects are never
  ordered.
- Authority lists: `A ⊑ B` iff every atom of `A` is below some atom of `B`.
- Normalization: host labels are lowercased; paths are canonicalized
  (separators collapsed, trailing separator removed) before comparison and
  rendering; a refinement that fails canonicalization is refused, not
  reinterpreted.
- Atoms carry resolved identities, never names: the table's effect names
  stand for the `effect_id` hashes the verifier already resolves from
  `spec/effect-taxonomy-v1.tsv`.
- Meet of two atoms (same effect): the lower one when they are ordered,
  `*.d1 ⊓ *.d2` is the deeper wildcard when nested, otherwise empty. Meet of
  two lists: every pairwise atom meet, empties dropped, then reduced to an
  antichain (drop any atom below another). This normal form is what nested
  combinators compute, so nesting never widens.
- Malformed refinements (an empty host label, a relative or `..` path, an
  empty secret prefix) are refused with E0821 where they are written, in a
  grant or a combinator argument; they are never reinterpreted.

### Serialization and the verifier chain

- The carrier is the verifier's existing `Resource { effect_id; scope;
  configuration }`: `scope` is the canonical refinement text and
  `configuration` names the grant configuration that supports the claim, as
  in v1.
- The effect-level envelope keeps v1's rules exactly: every call and proposal
  list still contains the frozen `Effect(id)` entries in taxonomy order and
  must equal the envelope byte for byte. Effect rows remain name sets.
- `⊑` applies to the **resource layer only**. `governance-verifier-v2` adds a
  `root-grant` authority list to the run bundle: the normalized atoms of the
  run's `--allow` flags (a bare `--allow net` is the top atom `Effect(Net)`;
  `--allow net=api.example` is `Resource(Net, "api.example", c)` with `c` the
  hash of that grant configuration). v1 bundles have no `root-grant` and keep
  their v1 verdicts.
- The v2 chain: every `Resource` of the call is `⊑` some `Resource` of the
  proposal with the same `effect_id` and `configuration`; every `Resource` of
  the proposal is `⊑` some atom of the root grant for that `effect_id` whose
  `configuration` is the same (the configuration hash names which grant
  supports the claim, so a claim supported by a different grant is
  uncovered), where a root `Effect(id)` is top and matches any configuration. Under a refined root grant for an effect, a call
  or proposal that claims that effect with no `Resource` refinement is
  uncovered (an unrefined claim is top, which a refined grant does not
  cover). Every failure names the widest uncovered atom.
- `Eval` budgets are not part of this grammar; step budgets belong to RT.1
  (task 214) after RF.2's invocation ownership.

## 4. What CAP.1 Implements

1. The order, normalization, list coverage, and meet in `src/` with a
   `authority.covers?` builtin; law suite (reflexivity, transitivity,
   meet-closure, coverage) proven exhaustively over a closed universe of three
   hosts, three paths, and three secret names.
2. `governance-verifier-v2`: the chain `call manifest ⊑ proposal authority ⊑
   root grant`, additive over v1, every failure naming the widest uncovered
   atom; v0/v1 bundles keep their verdicts.
3. `net.only`, `fs.under`, `secret.only` combinators refusing with E0820
   ("an operation was attenuated away by an enclosing boundary"), distinct
   from E0814 ("never granted"), audited inside a gate per D-CAP0.2;
   nested-order transcripts identical in both orders; malformed refinements
   E0821.
4. `--allow net=HOST`, `--allow fs=PATH`, `--allow secret=PREFIX` grant
   syntax producing the root-grant atoms above; bare `--allow net` stays top.
5. Backends: the combinators are ordinary prelude terms over one builtin, so
   the interpreter and the native backend both need `authority.covers?`; the
   native intrinsic ships in the same slice, and until it does `jac build`
   refuses a program that reaches it with the existing E1101.
6. Nested membranes (GM.12, task 153, done): a combinator inside an inner
   membrane narrows before the inner layer forwards, the v2 chain is checked
   at every layer against the same root grant, and meet-closure is what
   guarantees that an inner allow can never widen what an outer layer
   permits; the exhaustive inner/outer pair suite from task 153 gains the
   attenuated cases.

Out of scope for CAP.1: ports, row-type refinement, dependent effects,
capability values as data, revocation, wildcard grammars beyond the table,
and any OS containment.

## 5. The Rest Of The Host Report

Items outside authority are routed, not decided here:

| item | status on Core main |
|---|---|
| 1 bytes value | a later protocol version; unchanged |
| 2 multi-file store population | store-reopen repair merged as APP.4 (Core PR 117, `041230b`); a project workflow is PKG.1 (task 217) |
| 3 `(Int,)` printed as `(Int)` | open display defect |
| 4, 5 names, kinds, and prelude identities | pending API.1 (Core PR #130, not yet on main): `jacquard interface emit` lists every export with its kind and exact hash |
| 6 `(effect, operation)` registry matching | spec pin, host-protocol follow-up |
| 7 `noncanonical-target-hash` | pending vector decision (task 206 follow-up) |
| 8 completed-but-unrepresentable failure | host-protocol follow-up |
| 9 handler deadline | confirmed host-owned (HP0.8) |
| 10 evidence pack | stale: published, recorded in host `COMPATIBILITY.md` at `21da229` |

## 6. Review Record

The external gate was verified by an independent fresh-context check on
2026-09-17 (host task 7 done and merged; cited Core pins are ancestors of Core
main; kit digests agree). Host PR 8 had no separate recorded review; that
verification stands as the reviewed step. This decision document is itself
reviewed before merge.
