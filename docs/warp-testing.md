# Warp — The Jacquard Testing Framework, Design Draft 0.1

Companion to the stdlib design; assumes its rings, conventions, and notation. "Warp"
is the working title only (the warp is the fixed set of threads the jacquard weaves
through, which is what a test suite is to a program). The library names themselves
live under `test.*` and `check.*`, because the stdlib's first principle says
predictable names beat clever ones, and that principle applies to its own tooling.

The framework has three unfair advantages, all inherited rather than built. Rows
prove hermeticity, so the checker sorts unit tests from integration tests and makes
flakiness impossible for the former. Handlers replace the entire mocking industry,
because injecting a fake world is what a handler is. Merkle hashing replaces test
selection, because a pure test's hash changes exactly when its transitive
dependencies do. Everything below is elaboration of those three sentences.

Unless a fence is labeled `jacquard doctest=...`, blocks in this design document
are signature catalogs, command sketches, cache-key notation, or explicitly
described pseudocode rather than complete source files. Executable fences are
kept byte-identical with fixtures by the docs-doctest lane.

---

## 1. Core: one effect, two test types

```jacquard doctest=warp-check-effect mode=check fixture=warp-check-effect.jac stdout=warp-check-effect.stdout stderr=empty exit=0
effect Check a where {
  check : (Bool, Text) -> ()
  fail : (Text) -> a
}
```

A test is an ordinary definition of an ordinary type. There is no annotation, no
naming convention, no registration call:

```jacquard doctest=warp-test-types mode=check fixture=warp-test-types.jac stdout=warp-test-types.stdout stderr=empty exit=0
type Test =
  | Case Text (() ->{Check} ())
  | Prop Text (() ->{Dist, Check} ())
  | Group Text (List Test)

type WorldTest =
  | WCase Text (() ->{Check, Fs, Net, Clock, Console} ())
```

Discovery is type-directed: `jacquard test` scans the name index for definitions whose
checked type is `Test` or `WorldTest`. The interesting part is the rows in the
constructor fields. `Case` holds a thunk with the closed row `{Check}`, so the
checker rejects any test body that touches the clock, the filesystem, randomness, or
anything else unhandled. You cannot accidentally write a flaky unit test; the
program does not typecheck. `WorldTest` is where world rows are legal, and the
unit/integration split stops being a convention enforced in code review and becomes
two types the compiler distinguishes.

One consequence stated as policy: the runner never retries a `Test`. A hermetic
failure is real by construction, and retry loops exist only in the `WorldTest`
lane, where the row admits an unreliable world.

## 2. Assertions

Dictionary-passing pays off here, since messages come from `Show` and comparison
from `Eq`, explicitly. This is an interface catalog: the function bodies live
in the prelude and standalone signatures are not complete surface source.

```text
check.true : (Bool, Text) ->{Check} ()
check.eq : forall a. (a, a, Eq a, Show a, Text) ->{Check} ()
check.some : forall a b. (Option a, b, Text) ->{Check} ()
check.fails : forall a | e. (() ->{Abort, Check | e} a, Text) ->{Check | e} ()
check.throws : forall a b | e. (() ->{Throw, Check | e} a, (b) ->{Check | e} Bool, Show b, Text) ->{Check | e} ()
```

`check.fails` deserves a note: testing a failure path means handling the failure,
so the assertion is itself a handler around the body, about five lines of ring 1.
The runner (`test.run : forall a | e. (() ->{Check | e} a) ->{| e} Report`) is a `Check` handler
that collects soft failures and catches `fail`; a `Case` whose report contains zero
checks draws a warning, so a test cannot silently assert nothing.

## 3. Handlers are the fixture system

Ring 3's world effects each ship a test handler, and together they make mock
libraries a category error rather than a dependency:

| handler | behavior |
|---------|----------|
| `clock.fixed(t)` | `now` returns `t`; `sleep` advances it, so timeout logic runs instantly |
| `fs.in-memory(files)` | a `Map Text Text` pretending to be a disk |
| `net.scripted(script)` | responses served from a list; running out is a failure |
| `console.scripted(lines)` | canned input, captured output |
| `infer.scripted / infer.cached` | canned or cache-backed model completions, per the whitepaper's `Infer` direction |

Composition is nesting, and a `WorldTest` that installs all its own fake-world
handlers becomes a `Test`, checked as such. That sentence is the migration path
from integration to unit coverage, and the types verify each step of it.

### Record and replay

Fixtures beyond hand-written scripts come from recording. Serialization uses the
language's own homoiconic form as the wire format. The record-shaped `Codec`
is deliberately pseudocode because records are unsupported, and the two test
entries are signatures without bodies.

```text
type Codec a = MkCodec { encode : (a) ->{} Code, decode : (Code) ->{} Option a }

test.record : (() ->{E | e} a, codecs) ->{E | e} (a, Log)     -- per world effect E
test.replay : (Log, () ->{E | e} a) ->{| e} a
```

A `Log` is a list of (operation, arguments, result) triples as `Code`, stored
content-addressed like everything else. That placement matters: a test referencing
a fixture references its hash, so editing a fixture changes the test's hash and the
cache (§6) invalidates itself with no bookkeeping. Replay has two modes. Strict
mode fails when the live op sequence diverges from the log, which turns every
recorded fixture into an interaction contract and makes behavior drift a test
failure with a diff. Loose mode matches by operation and arguments, for tests that
should tolerate reordering.

## 4. Properties: generators are distributions

A generator is a `Dist` computation, so the property system is a reuse of ring 2
rather than a subsystem. These are signature sketches with omitted bodies and
an ellipsis standing for additional combinators, so they are not executable.

```text
prop.for : (Distribution a, (a) ->{Check | e} ()) ->{Dist, Check | e} ()

gen.list : (Distribution a, Int) ->{Dist} List a
gen.option, gen.result, gen.pair, ...            -- combinators over Distribution
```

The flagship behavior falls straight out of the M3 thesis. The same `Prop`, byte
for byte, runs under two handlers. This fence is a shell command sketch, not
Jacquard source.

```console
jacquard test                      -- sampling handler: N random cases, seeded
jacquard test --exhaustive         -- enumeration handler: every case, budget-bounded
```

Under sampling it is QuickCheck. Under enumeration, for generators with small
finite support, the identical property becomes a proof over the whole scope, and
the runner reports "verified exhaustively (128 cases)" instead of "100 samples
passed". Small-scope exhaustiveness stops being a separate tool with separate
generators; it is a flag.

### Shrinking without shrinkers

Shrinking follows Hypothesis rather than QuickCheck: shrink the choices, never the
value. The sampling handler already sits between the generator and its randomness,
so it records the choice log (which distribution, which outcome) as it runs. On
failure, the shrinker edits the log toward canonical simplicity (delete spans,
move `UniformInt` choices toward the low bound, prefer earlier `Categorical`
entries, prefer `False`) and replays the generator with logged choices forced,
sampling fresh only past the log's end. Every candidate the shrinker produces is
a value the generator could emit — candidates that break positional alignment
across sample sites are detected as divergence during replay and skipped, never
misreported — so invariants encoded in the
generator survive shrinking and per-type shrinker functions do not exist anywhere
in the framework. Honest limit: shrink quality depends on each distribution
declaring which outcomes count as simpler, and that ordering is part of ring 2's
contract per constructor.

One asymmetry between the two prop handlers, stated so nobody trips on it: the
SAMPLING driver ignores `observe` (it resumes with unit and drops the weight);
only the EXHAUSTIVE driver scales and prunes branches by observation weight. A
`Prop` that conditions its generator therefore only means what it says under
`--exhaustive`; under sampling the condition is silently inert. Rejection-style
resampling for the sampling lane is future work.

## 5. Fault simulation

One small effect turns the fixture handlers into a simulation rig:

```jacquard doctest=warp-fault-effect mode=check fixture=warp-fault-effect.jac stdout=warp-fault-effect.stdout stderr=empty exit=0
effect Fault where {
  flaky : (Text) -> Bool
}
```

The scripted world handlers consult `flaky` before each operation and simulate the
failure (timeout, refused connection, missing file) when told to. Three handlers
interpret it. This list names handlers and arguments but omits complete calls
and surrounding test bodies, so it is intentionally elliptical pseudocode.

```text
fault.none                       -- happy path
fault.random(p, seed)            -- chaos with a replayable seed
fault.all                        -- multi-shot: explore BOTH answers at every site
```

`fault.all` is the dev plan's Choose smoke test grown up. It resumes each `flaky`
site twice, so a test body with n fault points explores all 2^n executions
exhaustively and deterministically, and "the retry logic survives every
single-fault and double-fault scenario" becomes a unit test instead of an outage
retrospective. Combined with `clock.fixed` and scripted worlds, this is
deterministic simulation testing in the FoundationDB style, assembled from
library parts, with the exponential budget capped by the same mechanism as
`--exhaustive`.

## 6. The cache, and what CI stops doing

Hashing is Merkle-transitive: a definition's hash covers the hashes it references,
recursively. So for a hermetic `Test`, one key says everything. The equations
below define cache keys mathematically and are not Jacquard expressions.

```text
memo key (Test)      = the test's own hash
memo key (Prop)      = (hash, mode, samples, seed)
WorldTest            = never cached
```

`jacquard test` consults the result store before running anything, and the
consequences are blunt. A reformat or comment edit reruns zero tests. A rename
reruns zero tests. Editing `list.map` reruns exactly the tests that transitively
depend on `list.map`, identified by no mechanism at all beyond hashes changing.
Test selection tools, dependency-tag hygiene, and "affected targets" computation
dissolve into a lookup. A green CI run on a no-op change verifies in the time it
takes to scan the index, and the cache is shareable across machines because keys
are content, so one developer's local run warms the team's CI.

Coverage gets the same semantic treatment: the interpreter records which
definition hashes were evaluated under test, and `jacquard test --coverage` reports
the store's reachable-but-never-executed definitions. That answers "what code has
no test touching it" at the definition level with zero instrumentation of source
text; line-level coverage via spans can layer on later.

## 7. Testing probabilistic code

Inference code is code, and it finally gets real tests. For discrete models,
enumeration makes assertions exact, so no statistics are involved. These are
interface signatures without term bodies, not complete executable source.

```text
check.posterior : (() ->{Dist} a, List (a, Real), Eq a, Show a, Real) ->{Check} ()
check.same-dist : (() ->{Dist} a, () ->{Dist} a, Eq a, Show a, Real) ->{Check} ()
```

`check.same-dist` is the one that changes practice: it asserts two models induce
the same posterior within tolerance, which is the refactoring test for inference
("the optimized model equals the reference model") that most PPL codebases
conspicuously lack. Sampled assertions exist for models too large to enumerate,
and because the sampler is seeded they are deterministic, hence cacheable; the
documented caveat is that a seed-pinned tolerance can silently overfit its seed,
so the guidance is enumeration wherever the support allows, and generous
tolerances with large N where it does not.

## 8. What a test file looks like

A minimal hermetic case uses the currently shipped constructor and assertion
names and is checked by `dune runtest`:

```jacquard doctest=warp-hermetic-case mode=check fixture=warp-hermetic-case.jac stdout=warp-hermetic-case.stdout stderr=empty exit=0
docs-test : Test
docs-test = Case("documentation example", fn () ->
  check.true(True, "surface doctest"))
```

The larger block below is deliberately pseudocode, not an implemented source
file. It abbreviates required assertion labels and uses placeholders such as
`fixture-log`, `request`, and model definitions that only make sense in a full
application fixture. Those omissions would produce arity and `E0301` unknown-name
diagnostics, so the block is excluded rather than weakening it into a misleading
doctest.

```text
suite : Test
suite = Group("list basics", [
  Case("reverse twice is identity (example)", fn () ->
    check.eq(list.reverse(list.reverse([1,2,3])), [1,2,3],
             eq.for-list(int.eq), show.for-list(int.show))),

  Prop("reverse twice is identity (all small lists)", fn () ->
    prop.for(gen.list(UniformInt(0, 3), 4), fn (xs) ->
      check.eq(list.reverse(list.reverse(xs)), xs,
               eq.for-list(int.eq), show.for-list(int.show)))),

  Case("head! of empty aborts", fn () ->
    check.fails(fn () -> list.head!(Nil)))
])

fetch-retries : WorldTest
fetch-retries = WCase("retry survives any two faults", fn () ->
  test.replay(fixture-log, fn () ->
    fault.all(fn () ->
      check.some(net.with-retries(request, 3), show.response))))

sampler-ok : Test
sampler-ok = Case("optimized model matches reference", fn () ->
  check.same-dist(fn () -> two-coins(), fn () -> two-coins-fast(),
                  bool.eq, bool.show, 1e-9))
```

(The eta-expansions around the named models are load-bearing: a top-level
definition's row is CLOSED at `{Dist}`, and the assertion's thunk parameter
needs an open row — the fresh lambdas get one. See the stdlib errata on
closed rows.)

`jacquard test` runs the first and third definitions hermetically with caching,
`--exhaustive` upgrades the `Prop` to a 256-case proof, and the `WorldTest` runs in
its own lane under whatever grants CI gives it. The signatures did the sorting.

## 9. Deliberately absent

No mocking or spy framework (handlers, §3). No retries on hermetic tests (§1). No
test ordering hooks or shared setup/teardown state, since fixtures are values and
handlers compose instead. No tag taxonomy for selection, because hashes select. No
per-type shrinkers (§4). No separate small-check tool (§4).

## 10. Decisions and dev plan reconciliation

New owner decisions, continuing the table: D12, discovery by checked type as
designed here versus a meta marker (default: by type). D13, the `Codec` story
ships with ring 3 world effects only, user effects bring their own (default: yes).
D14, the name (default: plain `jacquard test`; "Warp" stays a document title).

Implementation slots in as Phase 6, after M3, since properties need `Dist` and
discovery needs the checker. Sized per the dev plan's scheme, inheriting its
global DoD: W6.1 `Check`, runner, assertions (M; report golden tests, zero-check
warning test). W6.2 test types, type-directed discovery, `jacquard test` (M; discovery
finds typed defs only, WorldTest lane gated by grants). W6.3 result cache (M; the
reformat-reruns-zero and edited-dep-reruns-dependents tests, cross-machine cache
hit test). W6.4 sampling runner with choice-log shrinking (L; a seeded failing
property shrinks to a documented minimal case; shrunk candidates proven
generator-valid by construction test). W6.5 exhaustive mode (M; a Prop verified
against a hand-enumerated case list; budget refusal is a clean diagnostic). W6.6
codecs, record/replay, drift modes (L; strict-mode drift failure golden; fixture
edit invalidates cache test). W6.7 `Fault` and `fault.all` (M; the 2^n exploration
counted exactly on a 3-site body). The multi-shot machinery these lean on is
already load-bearing by W2.4, which is why none of this phase is research.
