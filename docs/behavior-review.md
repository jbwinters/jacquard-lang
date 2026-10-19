# Behavior Review (RW.8): Comparing Two Checked Versions Over Declared Cases

- Status: implemented (`src/behavior_review.ml`, `jacquard review run`,
  `test/cli/review.t`). It makes the owner-approved design concrete: `docs/designs/behavioral-change-review.md`
  (DES.1) §4.1–§4.5, with the owner decisions of 2026-10-18: the report contract
  as designed, exact-conjunction grouping only, the `jacquard review` group,
  explicit named adapters, entry compatibility by **entry contract** (§3), and
  worlds as hermetic observable root handlers plus value domains (§2).
  Probability and cost (§4.4) are REV.1; `review replay`/`export` (§4.6) are
  REV.2.
- Deviations from DES.1, each recorded here: entry compatibility compares the
  entry contract instead of `interface diff` (that diff calls every changed
  term identity breaking, so it would refuse every behavior change; owner
  decision); the counts add `inconclusive` (OBS.1 comparisons can be
  inconclusive, which must never count as agreement); conditions may use
  declared derived fields (§7), as DES.1 §6 already does; a policy pinned to an
  interface is refused (§3); the root world is modeled by pure handler terms
  rather than `relate`'s dry twins, which still read the live filesystem,
  terminal and clock and keep RNG state across runs (§2).

## 1. The command

```console
jacquard review run --old OLD.jac --new NEW.jac --cases CASES.jac --entry NAME
    --domain NAME [--domain NAME]...  [--field NAME]...  [--adapter NAME]
    [--handle OP=NAME]... [--wrap NAME]  [--policy POLICY]
    [--fuel N] [--max-cases N] [--sample N --seed S] [--case K] [-o REPORT]
    [--prelude DIR]
```

Exit status follows `relate`: 0 when every declared case ran and agreed; 1 when
any case differs; 2 when nothing differs but some case failed, was
inconclusive, or was not run; 3 when the request is refused before any case
runs; 124 for command-line errors.

## 2. Versions, cases file, domains and worlds

**Assembly.** Each version is checked as one source: the version file's bytes, a
newline, then the cases file's bytes, in a fresh private scratch store
(`Frontend` preparation of a single source, as `jacquard test` assembles suites).
The cases file may name the version's types, constructors and terms. It must not
declare a name that the version declares, and must not contain top-level
expressions; either is E1010. The review appends a generated driver whose
names all start with the reserved prefix `review-driver-`; neither file may
declare such a name (E1010). Nothing is installed in a user store.

**Entry.** `--entry NAME` names a term both versions define, with n ≥ 1
parameters (D5 uncurried). `--domain NAME` is given exactly n times, in
parameter order: each names a cases-file term of type `List a_k` or
`Distribution a_k` (a prelude distribution value: `Bernoulli`, `Categorical`,
`UniformInt`), where `a_k` is the entry's k-th parameter type. DES.1's "world
values" (§6's availabilities) are simply further parameters with their own
domains; DES.1's input/world distinction is kept as declaration order only.

**Domain values.** Each version evaluates its own domain terms in a
**preparation invocation**, separate from the run invocation, with its own fuel
allowance equal to `--fuel` and no root handler; a failure or fuel exhaustion
there is E1012 with its cause. A `List` contributes its elements
in order; duplicates are kept as distinct cases. A `Distribution` contributes
its support in declaration order (`Infer_dist.support`), equal values merged at
their first position with summed weight, zero-weight values dropped; its
weights are recorded for REV.1. An empty domain, a non-finite or negative
weight, a uniform range above 10,000 values, or a value containing a secret,
closure, continuation, operation, task, channel, hash, code value or other
kind outside Int, Real, Text, constructors (including Bool and lists) and
tuples is E1012. The two versions' domains must be equal: element by element, data-v1
renderings (constructors qualified by identity) and weights of the merged
supports are byte-equal, and each domain value itself (a distribution value
included) renders equal. Otherwise E1013.
No value crosses from one store to the other: each version runs its own equal
values.

**Cases.** The cases are the product of the domains, the first parameter
outermost, each domain in its order (DES.1 §6: priority outer, availability
inner, so `Low × (Up, Down, Down)` is case 11). Cases are numbered from 0.
`--max-cases N` (default 10,000) is the run budget: cases from N on are
`unrun`. The product is enumerated in full before running, so a product above
1,000,000 cases is refused (E1012).

**Sampling.** `--sample N --seed S` (both or neither; 1 ≤ N ≤ `--max-cases`;
every domain a `Distribution`; otherwise E1015) draws N cases instead of
enumerating, and the exhaustive product cap does not apply. With
`Infer_dist.Rng`: `root = Rng.make S`; parameter k's stream is the result of the
(k+1)-th call of `Rng.split root` (streams taken in parameter order before any
draw); case i's value for parameter k is the (i+1)-th `Infer_dist.draw` from
stream k over domain k's merged, zero-dropped support in declaration order
(inverse CDF over the weights normalized by their sum; `UniformInt` is
materialized, so its 10,000-value bound applies). A domain whose total weight is
not finite and positive is E1012. Both versions draw from equal domains with the
same streams, so they draw equal values. Duplicate draws are kept as distinct
cases. The review status is `sampled`.

**Worlds.** A root world is a set of **modeled operations**: `--handle OP=NAME`
installs, at the root of each version, a handler for the operation each version
resolves the name `OP` to, which answers every call by applying the cases-file
term `NAME` to the call's arguments and resuming with its result. `NAME` must
have the operation's parameter and result types and an empty effect row (it is
pure, so a case cannot depend on another case's handler state). These
operations reach the root, so the policy records them and their arguments and
results are compared. No other root handler, no grant, and no live handler is
ever installed: any other operation that reaches the root fails the case.
`--wrap NAME` names a cases-file handler term `(() ->{e} r) ->{e'} r`; a case
then runs `wrap(fn () -> entry(x1, ..., xn))` as a closure application.
Operations a wrap handles never reach the root, so they are not observed (OBS.1
records root operations only). **Missing world configuration** is refused
(E1012) statically: the effect row of the entry's (or adapter's) checked scheme,
less the effects the wrap's scheme discharges, may contain only effects every
one of whose operations is `--handle`d.

**Adapter.** `--adapter NAME` names a new-version term (in NEW or the cases
file) whose entry contract equals the **old** entry's; the review then compares
the old entry against the adapter, and the adapter's identity joins the
request. This covers changed parameter order, arity or labels over unchanged
types. Domain values are still required equal in both versions, so a changed
*type* is refused (E1013) even with an adapter: mapping values between type
identities that exist in only one store is out of scope for RW.8.

## 3. Entry contract and refusals (exit 3)

The **entry contract** of a version is taken from its interface-v1 export of
the entry (or adapter) name: the checked signature text (every referenced
identity spelled as its hash, so names do not matter; its parameter list fixes
the arity) and the call labels, encoded as `positional` when the term has no
call-ABI companion and otherwise as its slots joined by `,`, each a label or `_`.
Its identity is `HASH_V0("jacquard-behavior-entry-v1" NUL signature NUL
labels)`. The two contracts must be byte-equal (E1011 otherwise, naming both
signatures). The signature is the checked, generalized scheme, so a version
whose entry ignores a parameter has a more general type than one that uses it;
declare the same signature (`assign : (Priority, Availability) ->{} Assignment`)
in both versions to compare them. Program identity (source and checked store), manifest identity
and entry-contract identity are reported separately.

| code | refusal |
|---|---|
| E1010 | a version plus cases file does not check, the cases file redeclares a version name or has top-level expressions, or a named term is missing or not a term |
| E1011 | the entry contracts differ (with no adapter), or the adapter's contract is not the old entry's |
| E1012 | a domain has the wrong type or count, is empty, has invalid weights or unsupported values, the product is too large, a world or wrap is missing or mistyped, an operation is `--handle`d twice, a field fails, or the case expression needs effects no installed world handles |
| E1013 | the two versions' domains are not equal |
| E1014 | the policy cannot apply to both versions (see below) |
| E1015 | `--sample`/`--seed` misuse, sampling a `List` domain, or a non-positive `--max-cases` or `--fuel` |

**Policy across two versions.** The policy (OBS.1, default policy if omitted)
is read once. Every operation it lists must be an operation of **both**
prepared versions (E1014). A policy pinned to an interface is refused (E1014):
a pin names one program's manifest, and two versions of a changed program never
share one (interface-v1 identity covers every exported identity). A malformed
policy is E1005 as for `relate`. An operation whose identity changed between
versions is two different operations: its events then differ, as they should.

## 4. Running and comparing

Each version runs all its cases in order inside one **run invocation** (the
modeled root handlers installed) with aggregate fuel `--fuel N` (default
10,000,000, `fuel-v1`): the two versions get N each. Each case is recorded by its
own recorder as a one-run observation transcript under the policy; the two
one-run transcripts are compared. Comparison checks a run's status and value
before its events, so a case whose result and effects both differ is kind
`decision`. A version's
run is `complete`, `failed code=C`, or `incomplete` (fuel spent mid-case); after
an incomplete run, that version's later cases are not started.

The **pair verdict** of a case:

| version runs | verdict |
|---|---|
| either incomplete or not started | `unrun` (both runs' states are kept) |
| both failed | `failed` |
| exactly one failed | `differ` kind `failure` |
| both complete, transcripts `Equal` | `agree` |
| both complete, `Divergent` at the run's value | `differ` kind `decision` |
| both complete, `Divergent` at an event | `differ` kind `effect` |
| both complete, `Inconclusive` | `inconclusive` |

`cases = agree + differ + inconclusive + failed + unrun` always holds.

**Review status** (DES.1 §4.3): `failed` when any case has a failed run in
either version, whatever its verdict (including an `unrun` pair whose other run
was incomplete); otherwise `sampled` for
a sampled review; otherwise `exhaustive-incomplete` when any case is `unrun`;
otherwise `exhaustive-complete`. The domain mode and every count are always
reported, so `failed` never hides that a review was sampled or incomplete, and
no rendering says "agree" without its scope ("on the 16 declared cases", "in
100 sampled cases"), nor while any case is inconclusive or unrun.

`--case K` runs only case K (both versions, full fuel N each). The request
records the selection (`select case=K`), so its identity differs from the full
review's, and every other declared case is `unrun`: the status is
`exhaustive-incomplete`, never a claim about the whole domain. Because fuel is
shared across a version's cases, a case run alone may complete where it was
`unrun` in the full review.

## 5. The request

```
jacquard-behavior-review-request format=1
core version=<v> prelude=<hex>
old source=<hex> entry=<hex> contract=<hex> interface=<hex>
new source=<hex> entry=<hex>|none contract=<hex> interface=<hex> adapter=none|<hex>
cases source=<hex>
domain index=0 kind=list|distribution old=<hex> new=<hex>
field index=0 name=<name> old=<hex> new=<hex>
handle op-old=<hex> op-new=<hex> term-old=<hex> term-new=<hex>
wrap none|<old hex>:<new hex>
policy <hex>
budget fuel-model=fuel-v1 fuel=<n> max-cases=<n>
select all|case=<k>
mode exhaustive|sampled count=<n> seed=<n>
```

Lines appear in this order; `domain`, `field` and `handle` lines are repeated
in declaration order. `entry`, `domain`, `field` and `wrap` are term identities in
each version's checked store; `source` is HASH_V0 of the exact file bytes. The
request identity is `HASH_V0("jacquard-behavior-review-request-v1" NUL bytes)`.
The new version's `entry` is its own `--entry` term (`none` if it has none);
with an adapter, `adapter` is the term actually compared and `contract` is the
adapter's.

## 6. The report

Every variable-length payload is framed as `<keyword> bytes=<n>` followed by a
newline, exactly n bytes, and a newline, so the format needs no escaping.

```
jacquard-behavior-review-report format=1
request bytes=<n>
<the request bytes>
status exhaustive-complete mode exhaustive
counts cases=16 agree=13 differ=3 inconclusive=0 failed=0 unrun=0
group index=0 kind=decision cases=3 first=11 condition=2
atom field=count-up value bytes=1
1
atom path=arg0 value bytes=<n>
Low#<hex>
witness case=11
arg index=0 bytes=<n>
<data-v1>
arg index=1 bytes=<n>
<data-v1>
old bytes=<n>
<observation-transcript bytes of this one run>
new bytes=<n>
<observation-transcript bytes of this one run>
case index=<k> verdict=<v> old=<state> new=<state>
claims declared-support-only
```

- Groups are ordered by kind (`decision`, `effect`, `failure`), then by first
  case. A group's condition is one of: `condition=<n>` with n atom lines;
  `condition=all` (there is no agreeing case to exclude: the condition is
  trivially true over the analyzed cases); `ungrouped` (no exact conjunction
  exists; the group lists its cases as `member case=<k>` lines).
- Witness runs are the per-run observation transcript bytes OBS.1 already
  produces under the policy, so only compared fields appear, with OBS.1's
  redaction and field limit.
- A `case` line is written for every case whose verdict is not `agree`, in case
  order, with each version's run state: `complete`, `failed:<code>`,
  `incomplete` (fuel spent mid-case) or `not-started`; consecutive `unrun`
  cases with the same states are compacted into one line
  `case index=<k> to=<m> verdict=unrun old=<state> new=<state>`. The lines are
  bounded by `--max-cases`.
- **Inputs and atoms are recorded in full data-v1.** They are values the
  reviewer declared in source, so the policy does not govern them; a domain
  value containing a secret or another unsupported kind is refused (E1012), so
  none can appear. They are never truncated, so a report names its cases
  exactly.
- The readable report (stdout) renders the same data in words, with each case's
  index and 1-based ordinal, the counts, the scope sentence, and the claim.

## 7. Grouping (exact conjunctions)

- **Atoms of a case.** For each parameter k, the data-v1 tree of its value
  yields `path=head` atoms in preorder: the root path is `arg<k>`; a
  constructor's head is its identity and its fields are `.0`, `.1`, ... by
  position (labels only label the rendering); a tuple's items likewise; a list
  is its `Cons`/`Nil` constructors, so element j of a list sits at
  `.1` repeated j times then `.0`; a tuple's head is `tuple/<arity>`; Int, Real
  and Text leaves are literal heads (their data-v1 spelling). Each
  `--field NAME` (a pure cases-file term taking the entry's n arguments and
  returning a supported data value; its checked row must be empty, E1012) adds
  one atom `field=<name>` whose head is its whole data-v1 value. Fields are
  evaluated in the old version for every case that will run, before any case
  runs, in their own invocation with an allowance equal to `--fuel`, so they
  never spend run fuel; a field that fails or exhausts that allowance refuses
  the review (E1012) before anything runs: a declared field must be total over
  the cases to run. An atom is
  false for a case that lacks its path.
- **Analyzed cases** are the cases with a verdict other than `unrun`. Conditions
  are claims about them only; for an incomplete or sampled review the report's
  scope says so.
- **Parts.** Differing cases are partitioned by kind. For each part, the
  candidate condition is the set of atoms every case in it satisfies. If no
  `agree` case satisfies every candidate atom, atoms are dropped one at a time
  in canonical order (parameters by index, paths in preorder, then fields in
  declaration order), keeping each drop only if no `agree` case then satisfies
  the remainder; the result is the group's condition (`all` if empty).
  Otherwise the part is `ungrouped`. A condition may also hold for failed,
  inconclusive or other-kind differing cases; only agreeing cases are
  excluded. The algorithm is deterministic and every condition is an exact
  conjunction over declared fields.
- **Witness**: the first case of the group in case order.

## 8. Determinism and witness replay in RW.8

The same request (same file bytes, flags and toolchain) produces a
byte-identical report. RW.8's witness replay is `--case K`: it reproduces the
witness's two run transcripts (given enough fuel), and the cram checks that
they are byte-equal to the report's witness blocks. Durable replay from a saved
report and `export` are REV.2: they will refuse unless every `source` hash in
the request matches the supplied files.

## 9. Compatibility

No change to the kernel, `.jqd`, HASH_V0, stores, `relate`, observation
policies or transcripts, Warp lanes or cache keys. New: the `jacquard review`
command group, `behavior-review-request`/`-report` format 1, and E1010–E1015
(rows in `docs/errors.md`; E1008–E1009 stay unassigned in the relational range).
