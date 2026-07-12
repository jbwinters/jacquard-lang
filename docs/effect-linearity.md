# Effect Linearity Modes — Design, Draft 0.1

Companion to the kernel spec, the effects runtime (tasks 70/71), and the
concurrency design. Origin: external review flagged that multi-shot
resumptions, the feature that makes Dist and Choose work, are precisely wrong
for resource-bearing effects, where resuming twice duplicates external actions
(double-charge, double-send). Task 71's copy-on-resume is the runtime half.
This document designs the static half: declared modes, checked before run.

## 1. Why this is Jacquard-shaped

The language already treats "what can this computation do" as a checked,
displayed fact. Linearity extends the same posture to "how many times can this
computation's suspension be re-entered," which is the other half of the
resource story. And because effect declarations are content-addressed
interface objects, a mode change is a visible, diffable, breaking interface
event rather than a silent semantic drift, which no other effect system gets
for free.

The law, stated once: **Dist, Choose, Fault, and search effects are
multi-shot; Async, Net, Fs, and resource effects are once.** Everything below
is machinery to make that law checkable.

## 2. The mode

Two modes per operation:

- `multi` (today's semantics): a handler clause may invoke the resumption
  zero, one, or many times.
- `once`: a handler clause may invoke the resumption **at most once per
  captured instance**. Zero is legal (abort-style clauses and cancellation
  are dropping, and dropping is allowed).

"At most once" (affine) rather than "exactly once" (linear) is deliberate:
requiring exactly-once would outlaw abort and cancellation. The honest
consequence is that `once` prevents duplication, not leaks; a dropped
continuation's memory is freed by the RC runtime, but external resources it
held are the cancellation-cleanup problem, owned by the concurrency design's
scope rules, not by this mode.

Per-instance matters and deserves its paragraph. A multi-shot region (an
enumeration) wrapped around code that performs a `once` operation is legal:
each resumed branch re-executes the perform freshly, and each fresh
continuation instance is itself resumed at most once. Semantically that is
"every world touches the world," which is correct and occasionally unwise
(enumerating over live Net), and unwisdom is a lint, not a mode violation
(§7).

## 3. Kernel change, hash-stable

`opspec` gains a mode field: `opspec = (name id, mode m, type* params, type
result)` with `mode = Once | Multi`. The serialization rule that keeps every
existing object hash unchanged: **`Multi` encodes as absence.** Only `once`
operations serialize the field, so the extension is invisible to the store
until someone uses it. This is the general pattern for extending the kernel
under content addressing and is worth naming in the kernel spec as such.

The exact bootstrap carriers are `(op fetch ((tref request)) (tref response))`
for `Multi` and `(op fetch once ((tref request)) (tref response))` for `Once`.
Explicit `multi` is rejected so absence remains the unique legacy encoding.
In `HASH_V0`, `Multi` contributes no byte; `Once` appends byte `0x01` after the
serialized result type. Until the surface-syntax phase lands, tools render a
`Once` operation in bootstrap notation rather than erase its mode.

Mode is part of the **interface hash**. Tightening an operation from `multi`
to `once` changes what dependents' handlers are allowed to do, so it is a
breaking interface change by construction, and `jac pkg diff` reports it in
authority terms: "op `fetch`: multi -> once (handlers may no longer resume
repeatedly)."

## 4. Surface syntax

Per-operation keyword, with an effect-level shorthand when uniform:

```
effect Net where
  once fetch : (Request) -> Response

once effect Fs where
  read : (Text) -> Text
  write : (Text, Text) -> ()

effect Dist where
  multi sample  : (Distribution a) -> a
  multi observe : (Distribution a, a) -> ()
```

Surface declarations **require** an explicit mode on every operation (or the
effect-level shorthand); there is no surface default. The kernel default
exists for hash compatibility; the surface refuses to let a human or model
not think about it, which matches the review culture everywhere else in the
language. The parser change is one keyword; this is the grammar headroom the
feedback asked for, spent.

## 5. Static discipline: the `Resume` type

The check lands in handler typing. For a `multi` operation, the resumption is
what it is today: an ordinary function value, `(b) ->{outer} ans`. For a
`once` operation, the resumption has the built-in type **`Resume b ans`**,
which is affine:

- A `Resume` may be **called** (ordinary application syntax), consuming it.
- On every control-flow path, a `Resume` value is consumed at most once;
  match branches each get their own budget.
- A `Resume` may be passed as an argument (the receiving parameter is
  `Resume`-typed and the callee is checked under the same discipline), so
  patterns like the membrane's `gate(policy, call, real, fake, k)` typecheck.
- A `Resume` may not be captured under `Lam` or `Quote`, stored in a data
  constructor, or returned; escape is how affinity gets laundered, so escape
  is the thing forbidden.

This is substructural typing scoped to exactly one built-in constructor,
which is a small fraction of the machinery of general linear types and buys
the entire stated benefit. The analysis is a per-function affine-usage walk,
the same shape as the exhaustiveness checker: syntactic, local, decidable.

The runtime trap stays as the backstop regardless: a second resume of a
`once` continuation is a defect with its own E-code, dynamically enforced
always (the copy-on-resume machinery already counts). Static where checkable,
dynamic everywhere, which is the same belt-and-suspenders stance the grant
system takes.

## 6. Stdlib mode assignments

Applying the law to the existing taxonomy: `once` for Net, Fs, Console,
Clock, Pg, Blob, Serve, Crypto, Log, Eval, Abort, Throw, State, Emit,
Approval, Audit, Secret, and the future Async and Channel. `multi` for Dist,
Choose, Fault, and search effects. The striking fact, worth putting in the
doc that announces this feature: almost everything is `once`. Multi-shot is
the rare, deliberate, magic case, and after this change the type system says
so instead of folklore.

## 7. Deferred: handler multiplicity badges

The real footgun this mode cannot catch statically is composition: passing a
Net-rowed computation to `dist.enumerate` re-executes fetches across worlds.
Catching it wants the dual annotation, a declared "this handler may resume
more than once" badge on handler-taking functions, so the checker can warn
when a multi-badged handler receives a row containing `once` effects. That is
a second design (it annotates function signatures, not effect declarations)
and is deferred with a marker; the dream-mode guidance ("simulate the world
before enumerating over it") covers the gap culturally until then.

## 8. Verification

Warp grows a hostile lane: for every `once` operation in the prelude, a
generated adversarial handler that resumes twice, asserting the defect fires
with the right E-code; the differential harness asserts interpreter and
native agree on the trap. The affine checker gets the usual golden-diagnostic
treatment, including the two messages that matter most: "resumed on two
paths" with both spans, and "`k` escapes into a closure" with the capture
site.

## 9. Phasing and decisions

L0 (small): dynamic trap and E-code, hostile Warp lane. Ships independently,
immediately, on the existing runtime counters. L1 (medium): kernel opspec
field with absence-encoding, interface-hash inclusion, pkg-diff rendering,
and connection to the L0 runtime backstop. L2 (large): `Resume` type and the affine
checker. L3 (small): stdlib assignments flip on, migration lint for
unannotated user effects. L4 (medium): surface `once`/`multi` keywords and the
effect-level shorthand; before L4, ordinary `.jac` lowering remains legacy
`Multi` and cannot print a `Once` declaration without a bootstrap fallback.

| ID | decision | default |
|----|----------|---------|
| D41 | mode granularity | per-operation, effect-level shorthand |
| D42 | defaults | kernel `multi` encoded as absence (hash-stable); surface requires explicit mode |
| D43 | static discipline | affine `Resume` built-in type; escape forbidden, passing allowed |
| D44 | stdlib assignments | per §6; almost everything `once` |
| D45 | handler multiplicity badges | deferred, marker retained for the enumerate-over-Net lint |
