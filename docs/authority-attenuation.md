# Authority attenuation: a decidable order on grants

Status: PROPOSED, with its open questions resolved by the CAP.0 decision
(`docs/release/authority-requirements/DECISION.md`, 2026-09-23): `Net` is
host-only in v0, attenuation refusals are audited and redacted, and the order
is trusted Core code exposed to the prelude as `authority.covers?` (which
supersedes the lean toward a prelude ring below). The `Eval` budget row is
deferred to RT.1. Drafted 2026-07-24 out of the post-rc3 review round;
revised 2026-07-25. When first
drafted this targeted the charter's then-deferred G3/G4 phases. Those phases
have since largely shipped — the live gate, the versioned governance
verifier (`governance-verifier-v0`/`v1`), Workspace forwarding, `jac
governance check`, and `jac why-effect` all exist on main — and they compare
authority lists by EQUALITY against frozen envelopes, with resource entries
"checked against configuration, never inferred from a row" (charter §12.2).
That makes this document's object sharper, not stale: the decidable order is
the upgrade from equality-against-configured-evidence to checkable coverage,
and it now has a concrete home in the shipped verifier chain rather than a
future phase.

Read first: docs/effect-membranes.md (charter phases and the deferred
`jac governance check`), docs/effect-taxonomy.md (Resource authority atoms
in proposals), docs/effect-linearity.md (modes, which this does not touch).

## Problem

Grants are binary per effect: `--allow net` is all of `Net`. Proposals
already speak a finer language — `Resource("Net", "api.example")` appears in
authority lists today — but nothing defines what it means for a grant to
cover a resource atom, for one authority list to subsume another, or for two
nested attenuating handlers to compose predictably. The shipped governance
verifier checks authority lists by equality against each operation's frozen
raw-authority envelope, and its own documentation is candid that resource
entries are configured evidence, never inferred. Equality is sound and
fail-closed, and it is also brittle: a policy cannot grant `*.example` and
have the verifier accept a call to `api.example`, and every attenuating
handler (`fleet.serve` narrowing Net to three hosts, a workspace facade
narrowing Fs to a subtree) is correct only by inspection.

Effect rows are name-sets and stay name-sets. That recorded decision is load-
bearing here: the order proposed below lives in carriers, handlers, and the
CLI, never in the row types, so the checker and inference are untouched.

## Design

**Atoms.** An authority atom is an effect name, optionally refined by one
resource pattern from a closed, per-effect refinement grammar:

    Net     host pattern        exact host, or one leading `*.` label
    Fs      path prefix         canonical absolute prefix, no globs
    Secret  name prefix         SecretRef name prefix
    Eval    step budget         Int, from docs/budgeted-eval.md

Every grammar is chosen for decidability by syntactic comparison alone: no
regular expressions, no overlap queries beyond prefix and label tests. An
unrefined atom `Net` is the top element for its effect.

**The order.** `a ⊑ b` ("a is at most b") is defined per effect:

- `(e, p) ⊑ (e)` — any refinement is below the bare effect.
- `(Fs, p1) ⊑ (Fs, p2)` iff `p2` is a path prefix of `p1`.
- `(Secret, n1) ⊑ (Secret, n2)` iff `n2` is a prefix of `n1`.
- `(Net, h1) ⊑ (Net, h2)` iff `h1 = h2`, or `h2 = *.d` and `h1` is a
  subdomain of `d` or equals a host under `d`.
- `(Eval, k1) ⊑ (Eval, k2)` iff `k1 <= k2`.

Authority lists order by coverage: `A ⊑ B` iff every atom of `A` is `⊑` some
atom of `B`. Both relations are decidable in one pass over pairs, and the
laws worth freezing are the ones nesting depends on: reflexivity,
transitivity, and meet-closure per effect. Meet-closure is what makes
membranes stack: two nested attenuations behave as their intersection and
never widen.

**Attenuating handlers as the operational side.** The prelude gains blessed
combinators whose observable behavior is the order, one per grammar:

    net.only    : (Text, () ->{Net | e} a) ->{Net | e} a
    fs.under    : (Text, () ->{Fs | e} a) ->{Fs | e} a
    secret.only : (Text, () ->{Secret | e} a) ->{Secret | e} a

Each forwards conforming operations outward and refuses nonconforming ones
with a typed, non-throwing result in the existing refusal style (a new error
code in the E08xx range, distinct from E0814 so transcripts distinguish
"never granted" from "attenuated away"). The row is unchanged by design:
the handler narrows which calls survive, and the CARRIER records what the
narrowing was. Nesting laws become Warp suites: `net.only(a, net.only(b,
thunk))` behaves as the meet of `a` and `b`, in every order, proven
exhaustively over a small closed universe of hosts and paths.

**CLI and gate.** `--allow net=api.example` extends the existing grant
grammar; the native main already accepts an equals spelling
(`--allow=EFFECT`), so the grammar has room. An unrefined `--allow net`
means top, as today. `jac governance check` (shipped) gains the chain
`call manifest ⊑ proposal authority ⊑ root grant`: three lists, two
decidable comparisons, and every failure names the widest uncovered atom.

## Interactions

- Governed membranes: the shipped verifier chain is where the order lands —
  a `governance-verifier-v2` whose authority comparison is `⊑` where v1's is
  equality, additive in the same way v1 was over v0. The forwarding and
  nesting laws the charter already enforces stay as they are; the order
  gives them the algebra they currently assert by construction.
- Budgeted eval: the `Eval` refinement gives budget attenuation the same
  algebra as resource attenuation, one document over.
- Approval: `Resource` atoms in proposals stop being decorative; a proposal
  asking `(Net, api.example)` under a grant of `(Net, *.example)` is
  checkably covered.
- Workspace facade: `workspace.read-file`'s eventual live driver is an
  `fs.under` composition rather than bespoke path logic.

## Evidence plan

- Warp law suite over a closed universe (three hosts, three paths, three
  budgets): reflexivity, transitivity, meet-closure, and coverage checked
  exhaustively; the universe is small enough that `--exhaustive` proves the
  laws outright.
- Cram: `net.only` refusal transcript with the new code; nested attenuation
  transcript identical under both nesting orders.
- Cram: `--allow net=api.example` grants the narrow call and refuses the
  wide one with E0814 naming the uncovered atom.
- A canary law: no combinator sequence widens authority; random nesting
  chains sampled by a Prop, exhaustive over depth 3.

## Non-goals

Row-type refinements, dependent effects, capability values passed as data,
revocation, wildcard grammars beyond the fixed forms above, and any ordering
between different effects. Also out of scope: retrofitting existing world
handlers. `fleet.serve` and its kin remain ordinary handlers; the
combinators are for boundaries where the narrowing itself is the reviewed
claim.

## Open questions for the owner

1. Does the `Net` grammar need ports, or is host-only the right v0 freeze?
   Ports double the grammar for one known use case (registry mirrors).
2. Should attenuation refusals audit when an audit handler is in scope, the
   way gate refusals do? Consistency argues yes; noise argues no.
3. Where does the order live: a prelude ring (checkable in-language, usable
   by the gate) or OCaml-side under src/ (cheaper, but the gate then trusts
   the host)? The ring is the better answer: a host-side order would have
   the gate trusting a judgment made outside the language's own evidence
   discipline, which is the failure mode docs/evidence-certificates.md
   exists to close. The charter's ring discipline points the same way.
