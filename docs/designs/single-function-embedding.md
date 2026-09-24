# DES.3 Single-Function Embedding

- Status: a design proposal with a follow-up backlog. This document neither
  implements the feature nor approves anything in it as a language, protocol,
  or package contract.
- Date: 2026-09-24
- Base: `main` of `jacquard-lang`, and `main` of `jacquard-host` at `21da229`.
- Pending planning input: API.1 `interface-v1` (jacquard-lang:216, PR #130).
  It was not yet on `main` when this was written.
- Owner decisions required before dependent implementation are listed in §10.

## 1. Question

An existing application should be able to call **one typed Jacquard decision
function**, get a useful result back, and optionally inspect how that result
was produced, without learning the host protocol.

The groundwork is real:

- a frozen protocol (`spec/host-protocol-v0.md`)
- a released serial worker (`jacquard host worker`)
- a conformance kit
- a working Python adapter in `jacquard-host`

The adapter's own requirements report shows what is still missing: typed
bindings, identities without archaeology, and an install-to-first-call path a
newcomer can follow. This design proposes that path for one ecosystem first.

## 2. Inventory Of Shipped Behaviour

| piece | where | what it gives today | gap for a first-time embedder |
|---|---|---|---|
| protocol v0 | `spec/host-protocol-v0.md` | one invocation per worker; closed, monomorphic, positional, first-order callable interface; exact closed effect row; closed `once` operation registry; strict JSON values (`int` as decimal text, `real` as raw bits, `text`, `hash`, `tuple`, saturated `constructor` by identity); E16xx diagnostics; cancellation at effect boundaries | raw envelopes and hashes |
| serial worker | `jacquard host worker --store DIR` (`docs/host-worker-v0.md`) | reopens a prepared store, exchanges effects in lockstep, exact exit statuses (0, 64, 70, 74), no root handlers, no retries | the store must be prepared by hand (`jacquard run DECLS.jac --store DIR`) |
| conformance kit | `spec/host-protocol-v0/kit/`, `docs/release/host-boundary/` | canonical fixtures and transcripts that adapters pin | — |
| Python adapter | `jacquard-host/src/jacquard_host/` (H0.1–H1.3 done) | `Host(store).invoke(target, interface, arguments, registry)`; `OperationRegistry.bind(effect_hash, op_hash, handler)`; `HostFailure(category, completion)`; deadline kill as host-owned evidence; about 18 ms to spawn, negotiate, and shut down a worker | the caller supplies hashes, a hand-built `Interface`, and protocol-shaped values |
| identity recovery | `jacquard_host/identities.py` | hashes by running `jacquard hash` over source files; parses `--print-sigs` text | the requirements report items 3–5: `(Int)` versus `Int` ambiguity, types and constructors not distinguished, prelude identities recovered by hashing prelude files |
| interface manifests | API.1, pending (PR #130) | `jacquard interface emit/verify/diff`: exports with exact identities, checked signatures, labels, and hidden members | not yet in protocol type form |
| Rust adapter | jacquard-host:8 (pending) | the same fixtures in a second language | — |

The host's requirements report
(`jacquard-host/docs/CORE-REQUIREMENTS.md`, v1) is the primary evidence for
what an embedder trips over. This design resolves items 3, 4 and 5 by
construction (§4.3). Item 9, the lack of a host-side handler deadline, is
handled by jacquard-host:10 (§4.7). Items 2 (multi-file stores; Core's store
repair, task 241, is done) and 10 (the published evidence pack) are
preparation concerns that `jacquard-host bind` absorbs by preparing its own
store (§4.1). Items 1, 6, 7 and 8 stay on their existing tracks.

## 3. User Scenarios And Ecosystem Choice

1. **A data or operations team** runs Python services and scripts and wants one
   auditable decision rule (a refund policy) that is typed, testable, and
   replayable, called from existing code.
2. **A research agent** in Python asks a Jacquard decision function whether an
   action is allowed. It needs the typed answer plus an inspectable record.
3. **A reviewer tool**, Host APP.1 (jacquard-host:11), already written in
   Python, calls two versions of a rule.

**Initial ecosystem: Python.** All three concrete users are Python. The only
working adapter, its conformance evidence, and the serial HTTP integration are
Python. The host repository is a Python package already. Rust (jacquard-host:8)
remains the second adapter that makes a stable v1 protocol claim possible
(protocol §12). It is not the onboarding target.

## 4. Proposal

### 4.1 Install to first call

```text
pip install jacquard-host                   # the adapter; requires `jacquard` on PATH
jacquard-host bind refund.jac --entry refund-decision -o refund_binding.py
python app.py
```

1. **Install.** `jacquard-host` is a pure-Python wheel.
   - It pins one protocol version (`jacquard-host-v0`) and one conformance-kit
     identity.
   - It declares the compatible `jacquard` Core version range.
   - On first use it runs `jacquard --version` and refuses outside the range,
     with a message naming both versions.
2. **Bind.** `jacquard-host bind` runs Core's checker and interface export
   (§4.3), prepares a private store under `.jacquard/refund/`, and generates a
   typed Python module.
3. **Call.** The application imports the module and calls one function.

### 4.2 Proposed example application code

The Jacquard side is ordinary checked source:

```jacquard
-- refund.jac (checked and run against Core main when this was written)
type Tier = | Basic | Gold
type Order = | Order(amount-cents: Int, days-since-delivery: Int, tier: Tier)
type Refund = | Approve(amount-cents: Int) | Reject(reason: Text) | Escalate

once effect Ledger where {
  prior-refunds : (Text) -> Int
}

refund-decision : (Text, Order) ->{Ledger} Refund
refund-decision(customer, purchase) =
  if int.gt?(prior-refunds(customer), 2) then Escalate
  else if int.gt?(order.days-since-delivery(purchase), 30) then Reject("outside the 30-day window")
  else
    match order.tier(purchase) {
      | Gold -> Approve(order.amount-cents(purchase))
      | Basic -> Approve(int.div(order.amount-cents(purchase), 2))
    }
```

The generated binding (excerpt; generated, never edited):

```python
# refund_binding.py: generated by jacquard-host bind; do not edit.
# core 0.2.x  protocol jacquard-host-v0  kit <kit-hash>
# target refund-decision  term <term-hash>  interface <interface-v1-hash>
from dataclasses import dataclass
from typing import Protocol, Union
from enum import Enum
from jacquard_host.binding import Binding

class Tier(Enum):          # nullary constructors become an Enum
    BASIC = "basic"
    GOLD = "gold"

@dataclass(frozen=True)
class Order:
    amount_cents: int
    days_since_delivery: int
    tier: Tier

@dataclass(frozen=True)
class Approve:
    amount_cents: int
@dataclass(frozen=True)
class Reject:
    reason: str
@dataclass(frozen=True)
class Escalate:
    pass
Refund = Union[Approve, Reject, Escalate]

class Ledger(Protocol):
    def prior_refunds(self, customer: str) -> int: ...

def refund_decision(customer: str, order: Order, *, ledger: Ledger,
                    inspect: bool = False) -> Refund: ...
```

The application:

```python
# app.py
from refund_binding import refund_decision, Order, Tier, Approve

class LedgerDb:
    def __init__(self, conn): self.conn = conn
    def prior_refunds(self, customer: str) -> int:
        return self.conn.execute(
            "select count(*) from refunds where customer = ?", (customer,)).fetchone()[0]

decision = refund_decision("c-17", Order(4200, 12, Tier.GOLD), ledger=LedgerDb(conn))
if isinstance(decision, Approve):
    pay(decision.amount_cents)
```

### 4.3 Generated typed bindings and interface compatibility

- **Core export (new; EMB.1).** `jacquard interface emit --format host-v0
  --entry NAME` prints one JSON document. The binding generator consumes only
  that document, never source text or printed signatures, which ends the host's
  identity archaeology (requirements report items 3–5). It contains:
  - the `interface-v1` identity and the entry term hash
  - the entry's parameters and result as **protocol §5.1 type descriptions**,
    with `(Int,)` versus `Int` unambiguous
  - every reachable constructor, type and operation, each with its kind,
    identity and field labels, including prelude types (`Int`, `Text`, `Bool`,
    `Option`, `List`)
  - the effect row and the operation modes
- **Refusal instead of lossy mapping.** The export refuses an entry the v0
  protocol cannot carry, with the protocol's own reason (E1604-class): a
  polymorphic, higher-order or `Code`/`Secret`/`Task` signature. So an
  unsupported function fails at bind time, not at the first call.
- **Stale bindings are refused.** The generated module pins the term hash and
  interface identity. At first call the adapter runs `jacquard interface verify`
  (API.1) against the prepared store. A changed rule that is still
  interface-compatible reruns `bind`, which regenerates cleanly. An
  incompatible one fails with `BindingOutOfDate`, showing the `interface diff`
  summary.

### 4.4 Ordinary data conversion

Conversion happens in the generated binding. The wire stays exactly v0.

| Jacquard | Python | notes |
|---|---|---|
| `Int` (63-bit) | `int` | a range check before sending; out of range raises `ValueError` naming the field |
| `Real` | `float` | exact bits both ways (v0 `real` is raw binary64); no decimal rounding |
| `Text` | `str` | UTF-8, no normalization (v0) |
| `Bool` | `bool` | the prelude `true`/`false` constructors, by identity |
| nullary-only type (`Tier`) | `enum.Enum` | one member per constructor |
| constructor with fields | frozen `@dataclass`, one per constructor; a type is a `Union` | labels become snake_case field names; unlabeled fields become `field0`… |
| `List a` | `list` | cons/nil chains on the wire, bounded by frame and count limits |
| `Option a` | `Optional[a]` when `a` is not itself an `Option`; otherwise generated `Some`/`NONE` | §10 item 2 |
| tuple | `tuple` | ordered |
| `Hash` | `jacquard_host.Hash` | opaque |

Everything else, such as closures, `Code`, `Secret`, `Task`, channels, or
polymorphic values, is outside the first-order interface (§4.9).

### 4.5 Operation registration

Each effect in the entry's closed row becomes a generated `Protocol` class, and
each `once` operation becomes a typed method. The caller passes one object per
effect as a keyword argument (`ledger=`). The binding builds the existing
`OperationRegistry` with the exact `(effect, operation)` identities, so the
caller never sees a hash.

- A missing keyword raises `TypeError` before any worker starts.
- A handler that returns a wrong Python type raises `ValueError` before
  encoding. Core would refuse it anyway (protocol §5.2), so the error is
  reported locally with the field name.
- A handler that raises `jacquard_host.HostFailure(category, completion)` maps
  to the frozen `effect_failure` pairs. Any other exception maps to
  `outside_failure`/`unknown`: the action may have happened, and the adapter
  never retries (protocol §9, jacquard-host:10).

### 4.6 Helpful errors

Every failure raises one exception type from `jacquard_host.errors`, and its
message says what to do next:

| exception | cause | example message |
|---|---|---|
| `CoreNotFound` / `CoreVersionMismatch` | no `jacquard` on PATH, or outside the pinned range | "jacquard 0.1.4 found; this binding needs 0.2.x. Install jacquard 0.2 or regenerate with a matching adapter." |
| `BindingOutOfDate` | the rule changed incompatibly since `bind` | "refund-decision's interface changed: parameter 2 Order gained field `region`. Rerun `jacquard-host bind`." |
| `InvalidArgument` | range, type or shape violation found locally | "order.amount_cents = 2**70 exceeds the 63-bit Int range." |
| `DecisionFailed` | Core outcome with a diagnostic (a runtime failure in the rule) | the Core diagnostic text with its source span, verbatim |
| `OperationFailed` | the host's own handler failed | the category and completion, plus the handler's exception as `__cause__` |
| `Cancelled` / `DeadlineExceeded` | caller cancel, or a host deadline (jacquard-host:10) | whether an operation's completion is unknown |
| `WorkerLost` | carrier loss (exit 74) or a Core invariant failure (exit 70) | the exit status and bounded stderr; never presented as a decision |

### 4.7 Cancellation and lifecycle ownership

- v0 runs **one worker per invocation**. `refund_decision(...)` starts a
  worker, invokes, answers effects, and waits for the terminal outcome and the
  exit. It always reaps the process, including on exceptions.
- **Cancellation.** The adapter can cancel only at effect boundaries (protocol
  §9: Core never preempts pure computation). The host enforces a wall-clock
  deadline by killing the worker; this is host-owned evidence under
  jacquard-host:10. A kill during an operation reports that operation's
  completion as `unknown`.
- **Ownership.** The application owns its handler objects and their
  resources. The binding owns the worker process. Core owns continuations and
  decides when each resumes. No thread, pool or persistent worker is created.
  The host's one-machine measurement, taken through its socket-fronted trial
  host, is about 18 ms to spawn, negotiate and shut down a worker. That figure
  is indicative, not a baseline: EMB.H2 re-measures on the `Host.invoke`
  embedding path. Worker reuse is deferred (§4.9).

### 4.8 Local simulation and optional inspectable execution

- **Local simulation needs no new machinery.** Pass fake handler objects:
  `refund_decision(..., ledger=FakeLedger({"c-17": 0}))`. The same binding runs
  offline, with no database or network. Jacquard-side Warp tests
  (`jacquard test`) cover the rule itself.
- **Inspectable execution.** `refund_decision(..., inspect=True)` returns
  `(decision, Inspection)`. `Inspection` holds what v0 already produces:
  - the Core and host frames
  - the effect requests with their arguments and responses
  - the outcome evidence
  - the bounded operator text

  `Inspection.render()` prints a readable trace, one line per effect exchange,
  and `Inspection.save(path)` writes the transcript. This is **within v0**:
  every item is already a frame the adapter holds.
- **Deferred extension.** Source-linked traces and forkable recordings (DES.0,
  jacquard-lang:253) would need Core to send span-carrying observations. v0's
  exact schemas reject additive fields (protocol §12), so this requires a new
  protocol version. It is identified here as an extension, not assumed.

### 4.9 Minimal first-order interface and deferred interop

**In the first release:**

- one named, monomorphic, first-order function
- positional and labeled arguments of the types in §4.4
- `once` world operations implemented in Python
- one invocation per worker
- synchronous calls

**Deferred, each needing its own contract:**

- polymorphic or higher-order entries
- callbacks from Jacquard into Python closures
- `Code`, `Secret`, `Task` and channel values
- streaming and multi-shot operations
- async or `await` bindings
- persistent or pooled workers, which need a protocol extension or v1
- a `bytes` value (requirements report item 1)
- non-Python ecosystems before jacquard-host:8

## 5. Packaging And Versioning

- **Package.** `jacquard-host` is a wheel from the `jacquard-host`
  repository. Its version is independent of Core's.
- **Pins.** The wheel pins three things in its metadata:
  - `protocol: jacquard-host-v0`
  - the conformance-kit identity it passes
  - `core: >=0.2,<0.3`
- **Binding header.** A generated binding records the adapter version, Core
  version, protocol, kit, term hash and interface identity.
  - A binding is valid only when all of them match at call time.
  - An adapter version change only requires regeneration when the binding
    format version (`binding-format: 1`) changes.
- **Core distribution.** Core is not bundled; the `jacquard` binary is
  installed separately. Bundling is deferred (§10 item 3).
- **Identity.** No `HASH_V0`, kernel, `.jqd` or store change. The only new
  Core surface is the `--format host-v0` interface export, which is
  additive.

## 6. Offline Walkthroughs

**Happy path.** This runs offline, with a fake ledger.

```text
$ pip install jacquard-host                         # from a local wheel in the exercise
$ jacquard-host bind refund.jac --entry refund-decision -o refund_binding.py
bound refund-decision (term 5e1c…, interface 0a9f…) → refund_binding.py
  parameters: customer: str, order: Order    result: Refund
  operations: ledger.prior_refunds(customer: str) -> int
$ python -c 'from refund_binding import *
from types import SimpleNamespace as N
print(refund_decision("c-17", Order(4200, 12, Tier.GOLD),
      ledger=N(prior_refunds=lambda c: 0)))'
Approve(amount_cents=4200)
```

**Failure paths.** Each prints its message and exits nonzero. No worker is
left running.

1. **Handler returns a string.** `ledger=N(prior_refunds=lambda c: "0")` →
   `InvalidArgument: ledger.prior_refunds returned str; expected int
   (Jacquard Int).` Nothing is sent to Core.
2. **Handler raises `ConnectionError`.** → `OperationFailed: ledger.prior_refunds
   failed (outside_failure, completion unknown): ConnectionError(...)`. The
   decision is not made and nothing is retried.
3. **The rule changes incompatibly** (`Order` gains `region`), and `bind` is
   not rerun → `BindingOutOfDate` with the interface diff.
4. **The rule fails at runtime** (for example, a division by zero added to the
   rule) → `DecisionFailed` with Core's diagnostic and the source line in
   `refund.jac`.
5. **A binding asks for an unsupported entry.** Take a hypothetical
   `rank-refunds : ((Refund) ->{} Int, List Refund) ->{} List Refund`, which has
   a function parameter. `jacquard-host bind` refuses it: "rank-refunds takes a
   function argument; the v0 host interface is first-order (protocol §5)."

## 7. Alternatives Considered

| alternative | why not now |
|---|---|
| Rust or JavaScript first | No concrete user yet. Python has the users, the adapter and the evidence. Rust follows as the second conformance adapter |
| An in-process FFI (a Python extension embedding the OCaml runtime) | Crosses the trust boundary D78 deliberately keeps as a process. It also needs a stable ABI and packaging per platform. The process carrier costs about 18 ms and is already conformance-tested |
| Dynamic binding without code generation (`jacquard.call("name", **kwargs)`) | No static types in the editor, errors discovered only at call time, and rule changes show up late. Generation gives both typing and staleness detection |
| A persistent worker serving many calls | v0 forbids a second invocation per worker. The 18 ms cost is acceptable for the first users, and reuse is a protocol extension |
| HTTP service wrapper | Out of scope for embedding. The host repository already owns a serial HTTP slice for other purposes |

## 8. Bounded First Release, Non-Goals, Compatibility

**First release:** EMB.1 in Core; EMB.H1 and EMB.H2 in Host (§11). Together
they give:

- Python bindings for one first-order function
- typed data conversion per §4.4
- operation registration through `Protocol` classes
- the error hierarchy
- fake-handler simulation and `inspect=True`
- the wheel with its pins
- the onboarding measurement

**Non-goals:**

- a sandbox or containment claim (D78)
- any protocol change in the first release
- async APIs, pools, and callbacks
- bundling Core
- a second ecosystem
- source-linked inspection, which needs a protocol extension (§4.8)

**Compatibility.** The first release is additive in both repositories. v0
frames are unchanged, and existing `Host.invoke` users are unaffected: the
binding is a layer over it.

## 9. Validation And Measurable Acceptance

- **Onboarding target (first success).** A Python developer who has never used
  Jacquard goes from a clean virtual environment to the §6 happy-path output
  in **at most 10 minutes and at most 5 commands**. They use only the README
  quickstart and the command output. This is measured in a scripted exercise
  with at least three participants, recording time, commands and confusions.
  Expert or author timings do not count.
- **Mechanical checks:**
  - `bind` and the first call, cold, each finish in under 2 s on the reference
    machine.
  - A warm call's overhead stays within the spawn cost that EMB.H2 measures on
    the embedding path, plus 5 ms for conversion. The ~18 ms trial-host figure
    is not the bound.
- **Conversion round-trip:** property tests over every §4.4 row, including
  63-bit edges, NaN and signed-zero bit patterns, non-ASCII text, and nested
  constructors.
- **Every §6 failure path** is a test with its exact message.
- **Staleness:** a compatible rule edit keeps the binding valid, while an
  incompatible one raises `BindingOutOfDate`, tested against API.1's
  `interface diff` classes.
- **Conformance:** the binding layer passes the pinned kit transcripts
  unchanged, so it adds no protocol behavior.
- **Core export:** `interface emit --format host-v0` round-trips every
  conformance-kit fixture interface and refuses each unsupported signature
  class with its reason.

## 10. Decisions Requiring Owner Direction

1. **Python first** (§3), with Rust as the second adapter, not the onboarding
   target.
2. **`Option` mapping** (§4.4): `Optional` where unambiguous, generated
   `Some`/`NONE` otherwise.
3. **Do not bundle Core in the wheel** for the first release.
4. **One worker per call** in the first release, and whether worker reuse is
   the first protocol-extension priority after v0.
5. **Generated bindings as checked-in files.** The alternative is generating at
   import time; the proposal is checked-in files, reviewable and diffable.

## 11. Follow-Up Backlog And Reconciliation

### Existing tasks reused

| task | relationship |
|---|---|
| jacquard-lang:205 HB.2 serial carrier and worker (done) | **Reused** unchanged as the transport |
| jacquard-lang:206 HB.3 conformance kit (done) | **Reused.** The binding layer must pass the pinned kit (§9) |
| jacquard-lang:216 API.1 interface manifests (pending) | **Reused.** EMB.1 extends its `interface emit` with the host format and depends on it |
| jacquard-host:2 H0.1 Python adapter (done) | **Reused** as the layer under the binding |
| jacquard-host:8 H2.1 Rust adapter | **Separate**, as the second ecosystem, deferred |
| jacquard-host:10 RT.H deadlines and cleanup (blocked) | **Reused** for deadlines and kill semantics (§4.7). EMB.H2's deadline errors depend on it |

### New tasks

| id | title | repository | depends on | priority |
|---|---|---|---|---|
| jacquard-lang:268 EMB.1 | `jacquard interface emit --format host-v0`: protocol type descriptions, reachable identities with kinds and labels, unsupported-signature refusals | Core | 216 | medium |
| jacquard-host:15 EMB.H1 | `jacquard-host bind`: typed Python binding generator with §4.4 conversion, `Protocol` operations, staleness check | Host | jacquard-lang:268 (cross-repo); host 2 | medium |
| jacquard-host:16 EMB.H2 | Wheel packaging with pins, the error hierarchy, `inspect=True`, the §6 walkthroughs, and the onboarding exercise | Host | host 15, host 10 | medium |

The Host tasks are created in the Host repository's own master tag. Their
cross-repository gate on jacquard-lang:268 is recorded in the task details,
because Task Master does not enforce cross-repository IDs.
