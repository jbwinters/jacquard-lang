# DES.5 Model Dependencies And Cached Reevaluation (MODEL.1)

- Status: accepted. Revision 3 followed two design reviews, and the owner
  adopted the recommended option of every decision in §6 on 2026-10-27.
- Implementation: in slices. Slice 1 (this revision) implements the document
  format, its validation against the source, and the dependency record and key
  (`src/model_doc.ml`, E1800-E1805). `jacquard model eval` with the cache
  (slice 2) and history, snapshots and `jacquard model explain` (slice 3) follow.
  §7 lists what each slice proves.
- Task: MODEL.1. Consumers: EXP.5 (`scenario-v1` is a MODEL.1 artifact plus
  forks), UNC.3 (assumption sets), the host's decision documents (APP.3), and
  MODEL.2 (measured incremental computation).
- Builds on: RF.1 sealed checked artifacts (212), API.1 `interface-v1` (216),
  OBS.1 observation policies and `data-v1` (225), INF.1 typed inference outcomes
  (223), fuel-v1 (214), Warp's hermetic result cache (`docs/warp-testing.md` §7).

## 1. Question

A decision document evaluates several named results from one model under
explicit assumptions. Today the only way to see the effect of an assumption
edit is to rerun everything (the picnic planner's rain 5 %, 30 %, 90 % reruns).
Nothing records which program, inputs, seed and budgets produced a result, so a
reader cannot tell whether a displayed number is still current.

MODEL.1 must:

1. bind each result to exactly what produced it;
2. cache a result only when that binding is complete and replayable;
3. after an edit, recompute the affected results, keep the others, and say why.

It is ordinary reevaluation with a content-addressed cache. It is not delta-based
incremental computation (MODEL.2 measures whether that is ever worth it), and it
does not extend Warp's keys.

## 2. What already exists

| mechanism | what it gives MODEL.1 | gap |
|---|---|---|
| HASH_V0 Merkle identity | a term's hash covers everything it references, so a program edit changes exactly the dependent entry hashes | nothing names inputs, seeds or budgets |
| RF.1 checked artifact, API.1 `interface-v1` | the checked program and its exported signatures by identity | — |
| OBS.1 policy identity, `data-v1` | a canonical, redacting rendering of values and a policy hash | — |
| INF.1 typed outcomes | posterior / impossible / exhausted / numerical failure with seed and bound metadata | — |
| Warp result cache | the pattern: content keys, a driver version, `WorldTest = never cached` | tests only; keys are fixed per lane |

## 3. Proposal

### 3.1 A model document: `jacquard-model-v1`

A model document is a small canonical text file next to the source. It is data,
not a new language form, so no kernel, `.jqd` or HASH_V0 change is needed:

```text
jacquard-model format=1
source picnic.jac
assumption rain = 0.3
assumption accuracy = 0.8
input forecast text forecast.txt
result best-venue entry planner.best-venue args rain,accuracy,planner.dry-world driver enumerate max-branches=10000 fuel=1000000
result p-wet@rain-5 entry planner.p-wet args 0.05 driver lw seed=7 samples=2000 fuel=1000000
result summary entry planner.summary args forecast driver run fuel=100000
```

- An **assumption** is a closed, pure Jacquard expression (a literal or a
  constructor application over literals), written in surface syntax. It is
  checked at the receiving parameter's type, and its identity is the HASH_V0 term
  hash of its canonical kernel form, the same hashing every definition uses. No
  value codec is needed, and an assumption cannot hold a closure, a capability or
  a `Secret` (their constructors are sealed). Constructors must be visible to the
  source (the ordinary resolver rules apply). HASH_V0 hashes `0.0` and `-0.0`
  (and every NaN) alike, and the resolver normalizes real literals with the same
  rule (`Resolve.normalize_real`), so an assumption's evaluated value is exactly
  what its identity names.
- An **input** is a named file read once as `Text` (UTF-8, refused otherwise;
  the prelude has no byte-string type). The model parses it; MODEL.1 defines no file decoding. The bytes read
  are hashed, evaluated, and retained as an immutable snapshot (§3.5).
- A **term argument** names an exported term (a modeled world handler, a value
  domain, a utility function), as RW.8's worlds are. Its identity is its term
  hash, so editing that model invalidates exactly the results that pass it.
  Live root handlers are never arguments in v1 (§3.3).
- A **result** names an exported entry term, its arguments in order
  (assumptions, inputs, term names or inline assumption expressions), a driver
  (`run`, `enumerate`, `lw`) with its bounds and seed, and a required finite
  `fuel` budget (fuel-v1). The entry's checked effect row must be discharged by
  the driver: `{}` for `run`, `{dist}` for `enumerate`/`lw`. A result reads
  nothing else: every dependency is an explicit argument (§5).
- An optional `policy FILE` line selects the OBS.1 policy that projects results;
  the default keeps every result in full (as `run --record`'s default does).
- Results are not arguments in v1, so a document has no result-to-result edges
  and no cycles; an unknown name is a diagnostic before anything runs. UNC.3's
  assumption sets are several results over one entry with different arguments
  (`p-wet@rain-5`, `p-wet@rain-30`); a later version may add a set shorthand.

The format, exactly (slice 1):

- The first line is `jacquard-model format=1`. Lines are LF-terminated; blank
  lines and lines starting with `#` are ignored. A document is UTF-8 and at most
  64 KiB.
- `source PATH` appears once; `policy PATH` at most once. Paths are single
  tokens, relative to the document's directory.
- `assumption NAME = EXPR`: the expression is the rest of the line. A
  closed-literal assumption is a literal, a constructor, or a constructor
  application or tuple over them, possibly annotated; it must resolve against
  the checked source, check, and use no sealed constructor of an opaque type.
- `input NAME text PATH`: the file is read once, must be UTF-8, and holds at
  most 16 MiB.
- `result NAME entry TERM args ARGS driver DRIVER SETTINGS`. `ARGS` is `none`
  or a comma-separated list without spaces; each item is a numeric literal (an
  inline assumption) or a name, looked up first among the document's
  assumptions and inputs and then among the source's exported terms. A declared
  name that is also an exported term is refused. The driver and its settings
  are `run fuel=N`, `enumerate max-branches=N fuel=N`, or
  `lw seed=S samples=N fuel=N`; each setting appears exactly once, and numbers
  are canonical decimals (fuel, bounds and samples positive).
- Names (`NAME`) start with a lowercase letter and use lowercase letters,
  digits, `-`, `_` and `@`; they are unique across assumptions, inputs and
  results.
- A result's entry applied to its arguments must check. Effects its row
  requires beyond what the driver handles (`dist` for `enumerate` and `lw`, and
  the scheduler infrastructure the runtime always discharges) are the result's
  world effects: it needs `--allow` and is never cached.

### 3.2 Dependency record and key

Each result has a canonical **dependency record**, line-based and
length-framed like `exploration-log-v1`, parsed strictly:

```text
jacquard-model-dependency format=1
entry <term-hex> signature <hex> labels <positional | l1,_,l3>
prelude <hex | none> core <version> engine interpreter driver model-driver-v1 fuel-model fuel-v1
driver enumerate max-branches=10000 fuel=1000000
policy <hex>
arguments 3
argument 0 assumption <hex>
argument 1 input text <hex>
argument 2 term <term-hex> signature <hex>
```

Every line ends with LF, including the last. Every field is a hash, a
canonical number or a fixed token, so the record needs no framing. The driver
line repeats the document's driver and settings. A signature is
`HASH_V0("jacquard-model-signature-v1" NUL S)` of the name-independent checked
scheme `interface-v1` renders. An assumption's identity is the HASH_V0 of its
resolved kernel expression; an input's is the HASH_V0 of its bytes. The prelude
identity is spelled as `jacquard run --record` spells it. Without a `policy`
line the policy is `observation-policy-v1` comparing the result, observing no
operation, with 1 MiB per field.

- The **key** is `HASH_V0("jacquard-model-dependency-v1" NUL record)`. It
  contains no key, outcome or provenance line, so it is not circular.
- The entry term hash transitively covers the entry's implementation. The
  entry's own checked signature and call labels (not the whole source's
  `interface-v1` identity) cover its contract, so editing a helper only
  `summary` reaches changes only `summary`'s key. The whole-source interface
  identity and source digest are provenance in the evaluation record.
- `model-driver-v1` versions the driver semantics (how a result is invoked,
  budgeted and projected), and `fuel-v1` names the fuel model, as
  `docs/computation-fuel.md` §5 requires `(fuel_model, budget)`.

### 3.3 One invocation, one budget, and what may be cached

A result is one invocation: the argument terms are evaluated, the entry is
applied under the driver, and the outcome is projected under the OBS.1 policy,
all on the one `fuel` budget. Branch and sample bounds are additional.

The stored artifact, `model-result-v1`, is the dependency record followed by one
tagged outcome:

| outcome | meaning | cached |
|---|---|---|
| `value <field>` | `run` completed | when the field is `data` |
| `inference <posterior\|impossible\|exhausted\|numerical> complete\|sampled <field>` | INF.1's typed outcome with its metadata | when the field is `data` |
| `failure code=C` | a deterministic runtime failure (including `unhandled`) | yes |
| `incomplete bound=fuel` | the budget ran out, during evaluation or projection (E0919) | **no**: fuel incompleteness is not a verdict (computation-fuel §5) |

Host JSON carries the same tags.

A result's outcome is cached only when it is fully replayable:

- the policy keeps the result (`result=compare`), and the projection is entirely
  `data` (no `unsupported`, `truncated`, `unfinished` or `missing` field). OBS.1
  renders closures, resumptions, capabilities, opaque values and `Secret`s as
  `unsupported`, so all of them (including a `Secret` inside an opaque value)
  refuse caching;
- the invocation ran with **no root handlers installed**: only the driver's own
  `dist` handling. Effect rows are not trusted for this (a handler covering some
  of an effect's operations can remove the whole effect from a row; see
  the handler-row follow-up), so any operation that reaches the root is an
  `unhandled` failure, never a world read. A document evaluated with `--allow`
  installs root handlers, and none of its results are cached;
- a native build is not cached (the cache is interpreter-defined in v1).

A refused result is evaluated and shown with its reason, never stored. Only
data-v1 text is persisted, after OBS.1 redaction; values a policy excludes are
never hashed into a record. Input files are the user's declared data and are
retained as given; the documentation warns against declaring secret files.

### 3.4 Evaluation and invalidation

`jacquard model eval DOC [--cache DIR] [--format json]`:

1. checks the source once (RF.1), reads every input once, and computes every
   result's dependency record and key;
2. serves a cached outcome when its key matches and otherwise evaluates and
   stores it (atomically, owner-only, under `.jacquard/model-cache/`);
3. prints, per result, `fresh`, `cached` or `uncacheable <reason>`, with the
   value, and appends an evaluation record (§3.5).

Invalidation is key inequality, per result. Editing `accuracy` recomputes
`best-venue` and keeps `p-wet@rain-5` and `summary`.

### 3.5 History, snapshots and explanations

The cache keeps, under a **document identity** (HASH_V0 of the document's
canonical absolute path, so two projects sharing a `--cache` directory never
collide):

- `snapshots/<hex>`: each input's bytes, each assumption's source text and the
  policy's bytes, immutable and content-addressed by their own HASH_V0, plus the reachable declarations of each entry
  and term argument in a content-addressed store (`jacquard store` objects), so a
  past result can be re-evaluated and diffed;
- `outcomes/<key>`: the cached projection;
- `history/<doc>/<result>`: append-only evaluation records: timestamp, key,
  dependency record, the **named bindings** (each argument's name, kind, term
  hash and snapshot reference), provenance (source digest, interface identity),
  outcome tag, and the previous record's key.

`jacquard model explain DOC RESULT` reports two things:

- **freshness**: the document's current dependency record (computed without
  evaluating) against the latest evaluation record: `current`, or `stale` with
  every differing component. A dependency whose snapshot is gone is `unknown`,
  never assumed current;
- **last transition**: the latest evaluation record against its predecessor,
  naming what changed then.

Assumptions render from their retained source text, entries by `jac diff` over
the retained declarations:

```text
best-venue: recomputed at 2026-10-27T10:05Z
  assumption accuracy: 0.8 -> 0.9
  entry planner.best-venue: callee planner.score changed
p-wet@rain-5: current (cached since 2026-10-27T10:02Z)
summary: stale (input forecast changed since the last evaluation)
```

A missing snapshot (a pruned cache) is reported as `history unavailable`, never
guessed. Host 13 consumes `--format json` of both commands.

### 3.6 Consumers

- **EXP.5 `scenario-v1`** = a dependency record whose arguments include the
  recording (an `input` snapshot), the model handlers (term arguments) and the
  fork list (an assumption), with seed and bounds. Executing it waits for EXP.3's
  replay handler; the record format already represents it.
- **UNC.3** passes worlds and utility functions as term arguments and assumption
  sets as sibling results.
- **Host 13** reads `model eval --format json` and `model explain --format json`.

### 3.7 Failure modes

| situation | behaviour |
|---|---|
| a named input file is missing or not UTF-8 for `text` | diagnostic before evaluation, naming the input |
| an assumption does not check at the parameter type, or is not closed and pure | diagnostic before evaluation |
| an unknown name in `args`, or a result named as an argument | diagnostic before evaluation |
| the entry's row needs a grant | `uncacheable world-effect`; runs only with `--allow` |
| a projection that is not entirely `data` | shown, `uncacheable <field kind>` |
| a corrupt or foreign cache file | ignored and recomputed, with a warning; never trusted |
| the Core version, engine, driver or fuel model changes | every key changes; nothing stale is served |

## 4. Compatibility

No kernel, `.jqd`, HASH_V0, store, Warp key, `relate`, or host-protocol change.
`jacquard-model-v1` and `model-result-v1` are new formats; one new command group
(`jacquard model`); new diagnostics for document errors. Warp keeps its own
cache; MODEL.1 does not reuse or extend it.

## 5. Alternatives considered

- **Trace reads dynamically** (record which assumptions a run touched): finer
  invalidation, but the evaluator would have to treat assumption reads as
  observable events, and a missed read silently serves a stale result. Explicit
  arguments make the key complete by construction.
- **Make assumptions `defterm`s and rely on Merkle hashes**: no new format, but
  an assumption edit becomes a source edit, rehashes every dependent term and
  loses the assumption/observation distinction DES.2 §4.2 requires.
- **Reuse Warp's result store**: Warp keys are per-lane and fixed by `warp-v2`;
  mixing documents into it would change Warp's contract.

## 6. Owner decisions (adopted 2026-10-27)

The owner adopted the recommended option of each decision.

1. **Document format.** A separate `jacquard-model-v1` text file whose
   assumptions are closed Jacquard expressions (recommended), or a section of the
   project manifest, or declarations in the `.jac` source.
2. **Explicit arguments only.** Results read assumptions and inputs only as
   declared arguments (recommended), rather than traced reads.
3. **Caching refusal set.** v1 never caches results whose entry needs a root
   world grant, or whose arguments or value contain a `Secret`, or whose rendering
   is truncated (recommended), deferring recorded-world snapshots to after EXP.3.
4. **Key contents.** Per result: the entry's term hash, checked signature and
   call labels; argument identities; prelude, Core version, engine, driver
   version, fuel model and budgets; the OBS.1 policy. The source digest and the
   whole-source interface identity are provenance only (recommended).
5. **Retention.** The cache retains input bytes, assumption text and reachable
   declarations so history can be explained and replayed (recommended); pruning
   makes old history `unavailable`.
6. **Command group.** `jacquard model eval|explain` (recommended) versus folding
   into `jacquard run`/`project run`.

## 7. Acceptance (from the task)

- Input, program, interface, world, seed and policy changes each invalidate
  exactly the affected results; unrelated changes retain them. Slice 1 proves
  this at the key level (`test/test_model_doc.ml`): an assumption, a helper
  reached by some entries, an input, a seed, a bound and the policy each change
  exactly the dependent keys, while an unrelated definition and a respelled
  equal literal change none.
- A fresh evaluation equals the cached result byte for byte.
- Missing snapshots and cycles fail clearly; Secret-bearing and non-hermetic
  results are refused caching with a stated reason.
- `explain` names every differing key component.
