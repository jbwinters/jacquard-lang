# Jacquard Core Unreleased Slice Log

Each change integrated after `jacquard-core-0.3.0` records its evidence and
the source inventory it reached when it merged. The 0.3 release documents in
`../0.3/` are frozen at their tag; this log, `README.md` and the live
inventory there carry the unreleased work until the next release moves them
into its own release directory. The intermediate inventory figures describe
the source checkout at each merge, not a release.

A handler clause that discards its continuation with `resume _` no longer
crashes `check`, `run` or `test` when its declaration is stored: the `.jqd`
encoding spells the wildcard binder as the first of `unused-resume`,
`unused-resume-2`, ... that the clause does not mention, and the declaration's
identity equals its named twin. A handler inside `quote` must name its
continuation (new E1245): quoted code is name-addressed data, and a generated
name could capture a spliced reference. `warp.t` runs check, run, fmt and both
Warp lanes on such a suite and pins the quoted refusal. The source inventory is now `1195 / 78 / 36`.

Cram transcripts no longer hide a tool's exit status behind a pipeline. Every
command that piped `jacquard`, `jac`, a demo script or a built native program
into an excerpting filter now writes the output to a file, prints `exit=N`
when the tool fails, and excerpts the file; 142 intentional refusals and usage
errors are now pinned in their transcripts. The new `cram-status` law
(`test/test_cram_status.ml`, two cases) parses each command with a small shell
lexer and fails on any pipeline whose non-final stage runs a tool or script in
any `test/**/*.t`; on the previous crams it reports 272 such stages. The
source inventory is now `1197 / 78 / 36`.

RW.8 adds `jacquard review run` (`docs/behavior-review.md`): two checked
versions of an entry are each checked with a cases file and a generated driver,
run over the product of declared List or Distribution domains (or a seeded
sample) under an observation policy, with operations modeled at the root by
pure terms, and compared case by case. The report groups differing cases by
exact conjunctions over declared fields, picks deterministic witnesses, keeps
agree, differ, inconclusive, failed and unrun counts, and writes the
behavior-review request and report format 1. `review.t` covers the DES.1 §6
scheduling example (16 cases, 3 differ, witness case 11), determinism and
witness replay, effect-only differences, adapters, budgets, sampling and every
refusal (E1010–E1015); `test_behavior_review.ml` adds four cases. The source
inventory is now `1201 / 79 / 36`.

DOC.1 brings `docs/SKILL.md` up to the current language and puts it under the
documentation doctest. Its examples called `console.print`, which does not
exist (E0301); they now use `println`, and every `jacquard` fence is a named,
self-contained doctest (20 examples: 7 run, 13 check). The guide now covers
the 0.3.0 surface it lacked (`try`, `opaque type`, scoped effect instances,
`--fuel`, `jacquard interface`), `jacquard review run`, the world operations
by name, positional constructor field syntax (E1225), `text.join-list` and
`text.slice` bounds, and current limits (the local `let rec` effect bug, E0610
for `jac diff` on runnable files, `--manifest` checking only top-level
expressions, formatter definition order, W1201 on parameters). Differences
from the 0.3.0 release are marked **Since 0.3.0**. The source inventory is now
`1201 / 79 / 56`.

EXP.1 adds `jacquard run --record LOG` (`docs/exploration-log.md`): the
evaluator's application frames carry their source span to the root operation
event (`Observation.Operation.site`), and the recording writes an owner-only
exploration-log-v1 of every root-reaching operation and Dist choice under an
observation policy, with exposed secret plaintext redacted and step and byte
bounds that stop the run (E1016) rather than truncate. Plain runs are
unchanged. `exploration-log.t` pins recording, source sites, output parity,
permissions, refusals, bounds, policy selection and a twenty-payload secret
check; `test_exploration_log.ml` adds two cases. The source inventory is now
`1203 / 80 / 56`.

EXP.2 adds `dist.named(name, d)` (`docs/stdlib.md`), a prelude function that is
exactly `sample(d)` under every handler. While `jacquard run --record` records,
the evaluator tags the `sample` a `dist.named` application performs with its
name and call site, and the exploration log writes a `choice-name draw=k` line,
so the draw is addressed by `(name, k)` (`docs/exploration-log.md` §2a);
unnamed samples stay position-addressed. Values, output and fuel of plain runs
are unchanged. `exploration-log.t` pins parity with `sample` under
`infer enumerate`, `infer lw`, a seeded root grant and Warp, the `(name, k)`
addressing inside a recursion, and that an in-language driver's choices are not
steps; the parser refuses a name on a non-choice step. The new prelude term
changes the prelude identity, so the demo projects are re-pinned. The source
inventory is unchanged (`1203 / 80 / 56`).

MODEL.1 slice 1 accepts the model-dependency design
(`docs/designs/model-dependencies.md`) and implements its document format and
dependency key (`src/model_doc.ml`): a strict `jacquard-model-v1` parser; the
validation of a document against its checked source (closed literal
assumptions, UTF-8 text inputs, exported term arguments, and each result's
application checked at the entry's types, with the effects beyond the driver's
recorded as world effects); and the canonical `jacquard-model-dependency-v1`
record with its domain-separated key. Refusals are E1800-E1805. No command uses
it yet; `jacquard model eval` and `explain` follow. `test_model_doc.ml` adds six
cases, including key-level invalidation for each dependency axis. The source
inventory is now `1209 / 80 / 56`.

MODEL.1 slice 2 adds `jacquard model eval DOC` (`src/model_eval.ml`,
`docs/designs/model-dependencies.md` §3.3a). Each result runs as one
invocation under its driver and fuel budget with no root handler, and its
outcome is projected under the document's policy inside that budget. A fully
replayable outcome is stored as `model-result-v1` under its dependency key,
owner-only and atomically, in `.jacquard/model-cache/`, and is served while the
key is unchanged. Fuel-bound, opaque, truncated, excluded and granted results
are shown with their reason and never stored; an entry that needs a root grant
is refused (E1806) unless `--allow` is given, which disables the cache. Corrupt
cache files are ignored and replaced (W1800). The slice also tightens the
slice 1 format: an injective call-label encoding, relative paths only, no
unapplied constructors with fields in assumptions, result names checked
against exported terms, the policy's interface pin, and single-descriptor
bounded file reads. `model-eval.t` pins fresh and cached runs, byte equality
with a fresh cache, per-axis invalidation, corruption, the refusal set,
`--allow`, `--no-cache` and JSON; `test_model_eval.ml` adds three cases. The
source inventory is now `1212 / 81 / 56`.

MODEL.1 slice 3a adds evaluation history and `jacquard model explain DOC
[RESULT]` (`src/model_history.ml`, `docs/designs/model-dependencies.md`
§3.5a). With a cache, `model eval` appends an owner-only history record per
result whenever its key changes, and snapshots assumption text, inputs and the
policy by content. `explain` computes each result's current dependency record
without evaluating and reports it as never evaluated, current, stale with every
differing key component, or history unavailable, plus what changed at its last
recomputation; a pruned snapshot is shown as unavailable. `model-eval.t` adds
the explain transcript and command-level invalidation for call labels and the
policy; `test_model_eval.ml` adds two history-format cases. The source
inventory is now `1214 / 81 / 56`.

MODEL.1 slice 3b completes `jacquard model explain`
(`docs/designs/model-dependencies.md` §3.5a). Each history record now names the
closure manifest of its entry and of each term argument: every reachable
declaration with its names and a retained snapshot of its body. When an entry
or term argument changes, `explain` lists the callees that changed, were added
or were removed. A refresh record no longer moves a result's evaluation time,
outcome or previous key. `model-eval.t` pins callee naming through a term
argument, stable history length over repeated evaluations, and the JSON of an
unknown result, callees compared by name and kind, and a pruned body making an
unchanged result unknown until the next evaluation restores it;
`test_model_eval.ml` adds a case for history records written before closures
existed. The history-v1 record gained an optional `entry-closure` line; no
release carried the earlier layout, and records without the line still parse.
The source inventory is now `1215 / 81 / 56`.

RT.2 slice 1 accepts the allocation-limits design
(`docs/designs/allocation-limits.md`) and adds `jacquard run --alloc CELLS`: a
process-wide `Alloc_meter` beside the fuel meter, `Eval.with_invocation
~alloc` with the same nesting, sticky exhaustion and deferred-refusal rules as
fuel, and E0921 (exit 2, incomplete). The evaluator charges alloc-v1 cells
before closures, tuples and constructor values, environment bindings, and
continuation capture and resumption; a memoized term's allocation is charged
once per invocation, so warm and cold runs cost the same. Natives, the other
drivers and the registry ceilings follow in later slices. `alloc.t` pins the
reported count, the exact boundary, exhaustion and the interaction with
`--fuel`; `test_invocation.ml` adds seven cases, including driver-made
resumptions under exact enumeration and warm/cold agreement on the budget that
ran out; `alloc.t` also shows a memoized initializer that allocates forever
stopping at the budget. The source inventory is now `1222 / 82 / 56`.

DOC.1 completes the SKILL.md fix: a new `skill-greet` example runs `greet`
with `grants=console` and checks what it prints, so a SKILL.md example now
exercises Console authority end to end. The source inventory is now
`1222 / 82 / 57`.

RT.2 slice 2a makes every driver treat allocation exhaustion as it treats fuel
exhaustion: the scheduler stops the whole run instead of failing one task,
exact enumeration and likelihood weighting keep E0921 instead of reporting a
model failure (E0902), an observation transcript records the run as
`incomplete code=E0921` (and refuses `failed code=E0921`), and bounded
commands exit 2. `Eval.exhaustion` names whichever budget ran out, fuel first.
`jacquard infer enumerate|lw` and `jacquard host worker` accept `--alloc`.
`test_invocation.ml` adds a case covering a wrapping native driver, likelihood
weighting, a scheduled task and a driver entered after exhaustion;
`test_observation_policy.ml` extends its status and impossible-transcript
cases; `alloc.t` and `host-worker.t` show the new options. The source
inventory is now `1223 / 82 / 57`.

RT.2 slice 2b adds `jacquard test --alloc CELLS`: each discovered test runs
under its own allocation cap, through the new `Eval.with_scope ?fuel ?alloc`
(one memo epoch for both caps; `with_fuel_scope` is now its fuel-only form). A
test that runs out is `INCOMPLETE ... allocation budget exhausted`, is never
cached, and makes the run exit 2 unless a test failed; Warp keys bounded
results on `alloc=alloc-v1:CELLS` after any fuel component, and its group,
property and runner guards treat either budget's exhaustion alike. A native
that returns a nested invocation's E0921, even wrapped in a diagnostic, now
exhausts the enclosing invocation, but only when an invocation actually ended
out of allocation while the native ran (`Alloc_meter.nested_exhaustions`): an
error that merely carries the code exhausts nothing. A scope whose enclosing
allowance is smaller than its cap reports that allowance as the limit.
`test_invocation.ml` adds two cases: allocation scopes (own cap, aggregate
reached and the limit that bound it, first budget out, no exhaustion left
behind after a smaller nested or scoped cap, memo cost per scope) and the
native error (wrapped nested exhaustion, and a forged E0921 that exhausts
nothing), both failing without their fixes; `alloc.t` shows `test --alloc`.
The source inventory is now `1225 / 82 / 57`.

RT.2 slice 2c charges every trusted native as the design's table says, through
the classes in `Native_alloc`. A native that knows its result's size charges it
before building it; `text.split` charges per piece as it goes; a rendering
counts its output bytes as they grow and stops at the remaining allowance, so
an exponentially shared value stops at the budget, and text it discards
(`code.hash`, `pmf`, an inference key) is charged too. Comparing without
rendering costs nothing; `code.diff` counts what it keeps and charges its text
before joining it; `code.form` costs one cell plus one per child. A
result of constant size is charged on return. Nodes are counted once each by
physical identity, a result does not charge what it shares with its inputs, and
likelihood weighting charges each run it retains, so `dist.sample-lw` and
`infer lw` stop at the budget even for a model that allocates nothing per run.
`test_invocation.ml` adds a case: every installed trusted native is classified,
exact costs, the boundary, rendering and join limits, distinct-node counting,
shared inputs, equal forms fitting their budget, and bounded sampling. Counts
that include natives grow: `alloc.t`'s chain costs 706 cells, and exact
enumeration pays for its keys. External reads and `eval` are next. The source
inventory is now `1226 / 82 / 57`.

RT.2 slice 2d charges root handlers, the grants that answer effects at the
root. A handler's result is charged on return for the nodes it adds to its
arguments (a scalar costs nothing, unit one cell, a file's text one plus one
per started 8 bytes); a handler that runs code, such as `eval-code`, is charged
by the evaluator instead, so its result is not charged twice. External text is
bounded before it is read: `read` checks the file's length against the
remaining allowance and refuses with E0921 without reading, an infer cache
entry likewise, and console lines are read at most one byte past the
allowance. `eval-code` charges one cell per kernel node before converting its
payload, counting a shared subform once per occurrence, so code shared
exponentially is refused instead of expanded. `test_invocation.ml` adds a case:
exact handler costs, a 256 MiB sparse file and a 2^22-node payload refused
without being read or converted, the bounded line reader, and the two handler
classes. The source inventory is now `1227 / 82 / 57`.

A follow-up ends console input once a line is refused as too long (owner
decision 2026-11-03), so no later read (the next test under `test --alloc`)
sees the rest of that line, which is never read; and corrects the `run --alloc`
help: a file is refused before it is read, a console line one byte past the
allowance. The root-handler case also covers a driver
dispatching a captured operation and a scope's own budget bounding a read.

Slice 3a adds the first registry ceilings (§4): `jacquard run --max-tasks N`
and `--max-channels N` bound the tasks retained (spawned, or a nested scope's
body) and the channels open at once across the whole run, counted by
`Retain_meter` and scoped by `Eval.with_invocation` and `Eval.with_scope` as
the allocation budget is. Entries are released when the run's scopes are torn
down, so a nested scope that finished early stays counted until its run ends.
The entry past a ceiling is the incomplete outcome E0921, naming the ceiling
(`Runtime_err.Ceiling_reached`), and sticky. Opening a channel now charges its
declared capacity as cells. `test_invocation.ml` adds a case (exact ceilings,
stickiness, a scope's own ceiling, release after an exception, the capacity
charge) and `test/cli/alloc.t` the command line. The source inventory is now
`1228 / 82 / 57`.

Slice 3b adds the frontier ceiling (§4): `--max-frontier N` bounds an exact
enumeration's pending entries, the support entries not yet explored at every
level of its depth-first search, in `Infer_dist.enumerate_v1` and
`enumerate_risk_exact`. A sample point retains its whole support as it is
materialized, each entry is released as its branch starts, and a search that
ends, however it ends, leaves none counted. Reaching it is E0921 naming
`--max-frontier`; allocation is reported before it and it before the branch
budget. `jacquard run` gains `--max-frontier`, and `jacquard infer enumerate`
and `infer lw` gain all three ceilings. `test_infer.ml` adds a case (the peak
in both enumerators, check order, a scope's own ceiling) and
`test/cli/alloc.t` the command line. The source inventory is now
`1229 / 82 / 57`.

Slice 3c adds the ceilings to `jacquard test` and `jacquard host worker`
(§6). `test --max-tasks`, `--max-channels` and `--max-frontier` bound each
discovered test through the same `Eval.with_scope` as its budgets: each test
counts from zero, one that reaches a ceiling is reported `INCOMPLETE` (naming
the ceiling) and never cached, and Warp keys bounded results on each ceiling
given (`max-tasks=N`, `max-channels=N`, `max-frontier=N`), as it keys on the
budgets (§5). `host worker` passes them to the invocation; a v0 target cannot
spawn, open a channel or enumerate, so none can be reached there yet.
`test/cli/alloc.t` shows the per-test ceiling and the cache keys and
`test/cli/host-worker.t` the worker flags. The source inventory is unchanged.

Slice 3d finishes RT.2's slice 3. `jacquard build` and `jacquard project build`
accept `--alloc`, `--max-tasks`, `--max-channels` and `--max-frontier` only to
refuse them with E1103, naming each one given, before compiling anything:
native code has no allocation or registry accounting (§7). `Eval.register_builtin`
now documents that a registered native ticks fuel and charges its own
allocation. The overhead (§8), measured against the parent of slice 1 on the
same suites and inference demos at both commits, is 0.1 % of median
wall-clock, within the 10 % threshold. `test/cli/alloc.t` shows the refusals.
The source inventory is unchanged.

`test_invocation.ml`'s registry case now also covers cancellation followed by
teardown (§8): a cancelled task stays retained until its scope is torn down,
so three cancelled tasks still need four slots, and the count returns to what
it was when a scope began, including a non-zero count.

`jacquard diff` now prints a readable report by default. Each change is
labelled with the part of the definition it falls in (`authority`, `signature`,
`body`, `clause N` of a match, or an effect's `op` or a type's `con`) and shows
both sides in surface syntax, naming each reference as the side that holds it
binds it; an unnamed reference shows `#` and 12 hex digits, and a reference that
reads the same on both sides but changed identity shows both identities. An
authority change prints the rows by blessed display name (an unblessed effect as
`name#<12 hex>`), then the review line of each removed and added effect. An
added term shows its annotated signature. `--paths` prints the previous report
byte for byte (kernel paths, `--syntax` notation, full hashes) for tools.
`test/cli/diff.t` shows a reformat, a body change that adds a call and widens
authority, a callee edit with its dependents and a rename in both modes;
`escrow.t` and `surface.t` follow. The source inventory is unchanged.

A handler now discharges an effect only when it has a clause for every one of
the effect's operations. A partial handler forwards its omitted operations to
the next handler out, so the effect stays in its residual row; before, the row
dropped it, so a program could check as pure and then stop on an unhandled
operation. Payload effects keep their existing refusal of partial handlers.
Shipped handlers that left an operation out now have a clause for it: the
console capture helpers in `docs/stdlib.md`, `test/cli/world.t` and the
formula notebook's interaction tests gain `read-line`, and the kernel fixtures
in `native.t`, `round-robin.t`, `checker-effects.t` and `test_check.ml` cover
`sleep`, the remaining Async operations and `read-line`. The interposing Check
handlers in `prelude/18-fault.jqd` forward `fail`, so their continuations now
carry `check` (`tiers.t`); no prelude signature changes.
`test/cli/partial-handler.t` and `test_effect_payload.ml` show the refusal, the
inferred row, and a complete outer handler agreeing in both engines. The
source inventory is now `1232 / 83 / 57`.

Behavior review hardening. With partial handlers now keeping their effect, a
`--wrap` that handles only some of an effect's operations leaves the effect in
the case's row, so the review refuses it statically until every one of its
operations is `--handle`d (`review.t`). The driver's prelude constructors and
domain types are taken from the pinned standard prelude identities only; a
modified `--prelude` that lacks them is refused (E1010) instead of being
matched by name. The case product is decoded on demand and domain elements are
read from arrays, so a 1,000,000-case product with `--max-cases 2` runs in
46 MB instead of 530 MB, with a byte-identical report. The readable report
drops only constructor identity qualifiers, so Hash values and quoted code keep
their bytes; a transcript comparison that cannot be made is an internal error
(`Bug_review_comparison`), never an inconclusive case; E1012 world messages
name effects in surface spelling (`Two`). `docs/behavior-review.md` now states
where named terms may live, that the cases file (and an adapter in it) checks
with both versions, and each `--fuel` allowance. The source inventory is now
`1234 / 83 / 57`.

Cram-status law hardening. The `cram-status` scanner now also sees the
scripts of `sh -c`/`bash -c`, wrapper options that take a value (`timeout -s
KILL 60`, `env -u`, `nice -n`, `xargs -I {}`, `time -f`; `env -S` counts as a
tool), a command or backtick substitution used as the command word, tools
inside process substitutions (whose status is never recorded), escaped
backticks inside backtick substitutions, `$((cmd) | ...)` as a command
substitution rather than arithmetic, `;&` and `;;&`, multi-digit and closing
descriptor duplication (`2>&10`, `2>&-`), and stray `)` or `;;` inside a brace
group, loop or if body, which no longer end the compound early. Today's crams
stay at zero violations; 25 of the new detector cases fail on the previous
scanner.
The crams that work inside a pretend checkout (`opaque-types`, the
`project-*` crams) write their captures to the cram's top directory, outside
the project trees. `scripts/dev/cram-status-mutation.py` reruns a cram once
per checked block with the `jacquard`/`jac` exit status shifted by 50 inside
that block only, and fails on any block whose run does not change
(`docs/ci-cd.md`). The source inventory is unchanged at `1234 / 83 / 57`.

Wildcard-continuation follow-ups. The surface printer now shows a continuation
reloaded from its `.jqd` carrier as `resume _` when the name is exactly the
spelling the encoding would pick for that clause (`Kernel.is_wildcard_resume`),
so a reloaded or spliced clause prints as it was written and re-encodes to the
same text; a referenced name, any other spelling, and every clause inside a
quote keep the name, since `resume _` is refused there (E1245). The printer
tracks quote depth as lowering does. `warp.t` pins `resume _` in a live
`unquote` (accepted) and inside a nested quote, with or without an inner
`unquote` (E1245). A unit case covers an operation parameter named
`unused-resume`, which moves the spelling to `unused-resume-2` with an
unchanged identity. The source inventory is now `1235 / 83 / 57`.

Abstract-types hardening, first part. The host boundary's opaque-type walk
(`Host_protocol_v0.boundary_type_supported`, now in the interface) fails
closed: a reachable identity the store cannot resolve to a type or effect
declaration is refused with E1604, since its representation is unknown. The
value guard caches the walk per identity across one value. Warp decodes a test
report by the prelude's constructor identities (`mk-report`, `cons`, `nil`,
`some`, `none`, `true`), so a value with the same constructor names is not a
report. `Prelude_identity.lookup_kind` no longer falls back to the store's
binding for a pinned name whose pinned identity is absent, so a stale bindings
golden or a store with a different prelude makes the builtin unavailable
instead of resolving it by name; names the prelude does not define still
resolve by name. The host preflight fixture now seeds the prelude's own
primitive declarations. The source inventory is now `1236 / 83 / 57`.

Abstract-types hardening, second part. Warp's test-tree walk (`run_value`,
`value_has_prop`) and its relational cache key (`relational_key_string`) read
`case`, `prop`, `group`, `wcase`, `same-under`, `vary-schedule`, `vary-world`,
`vary-value`, `cons` and `nil` by the prelude's identities, so a value built
from same-named constructors is not a test and cannot reach a cached verdict.
Bundle build and read refuse (E1721) when the prelude's `eval-code` and `Eval`
identities are absent, instead of finding nothing to refuse. E0702 names a
bound prelude name whose pinned declaration is absent, instead of calling it an
unexpected kind. `opaque-types.t` lists every changed export for each migration
step and adds a constructor that gains a field beside the rename. The source
inventory is now `1237 / 83 / 57`.

Abstract-types hardening, third part. A C runtime unit test pins `jq_display`
redaction: an opaque value inside a constructor or a tuple renders as
`<opaque NAME>`, while `jq_show`, the structural key, keeps the representation.
E1721's summary and next step now cover a prelude that lacks the pinned
`eval-code` and `Eval` declarations, and `docs/errors.md` lists that cause.
E0702 says a bound prelude name's pinned declaration is absent, without
guessing why. More forged-constructor tests cover Warp's `wcase`,
`vary-world` and `vary-value`, `group` and `cons` in the property check, and
the relational key; another checks that the prelude's own `eval` declaration
yields both eval identities. The source inventory is unchanged at
`1237 / 83 / 57`.

Abstract-types hardening, fourth part. Hash-valid forged bundle objects, rooted
by a forged test entry, are refused (E1738) when they use a dependency's sealed
constructor applied, unapplied or inside a live splice; constructor syntax in
quoted data is not a use. A consumer term calling the private constructing
member of a dependency's recursive group is refused, while one calling the
group's exported member verifies. A dependency context forged to export a term
constructing its consumer's opaque type is refused, and a refused import leaves
no declaration, object file or name in the importing store. `project-bundle.t`
builds against a prelude copy without the `eval` effect and is refused with the
absent-identity cause of E1721. The third part's forged Warp tests also covered
`same-under` and `vary-schedule` in the test-tree walk. The source inventory is
now `1241 / 83 / 57`.

Abstract-types hardening, fifth part. Opaque types cross a host session in
neither direction: a configured operation that returns an opaque type, takes
one, or returns one inside a transparent wrapper is refused when the session
starts (E1604). A forged `effect_ok` carrying an opaque constructor, alone or
inside a transparent one, is refused as an invalid response (E1608) without
resuming the computation or recording an observation. The response decoder
refuses the opaque constructor before the result type is checked, but the
session reports every undecodable response as one E1608, so these tests show
the refusal rather than which check made it; the decoder's opaque refusal is
pinned by its cause on the invoke path. An opaque request argument is refused
(E1604) before any request frame carries it, and an opaque invocation result
ends in an error terminal (E1604) that does not carry it. No terminal names
the constructor. The worker refuses the same signature before any request and
the same forged response after one. In bundles, the forged-constructor cases now
also show the refusal comes from the region rule, a constructor pattern is a
use, quoted data carrying the constructor's identity is not, the recursive
group's two members are checked to share one declaration, a refused import
leaves the store's name file, object directory and bindings unchanged, and
the reader refuses (E1721) a bundle forged to name a prelude without the
`eval` effect. The source inventory is now `1246 / 83 / 57`.

Abstract-types hardening, sixth part. The native and inference matrix: two
native gauntlet twins, byte-identical on both engines and with their
interpreter output pinned in `opaque-matrix.t`, run governance authority
validation, likelihood weighting and `support` after a file rebinds `bool`,
`result`, `ordering`, `option`, `list` and `pair` as its own opaque types (the
builtins still build prelude values), and nested opaque outcomes through
enumeration, nested likelihood weighting and `pmf` (enumeration keeps two
opaque outcomes, each nested driver keeps two, `pmf` finds 0.7, and all print
redacted). `opaque-matrix.t` builds a project natively whose root rebinds
prelude term names while calling its dependency, with output identical to
`project run`; a root that runs an entry may not rebind a prelude constructor
name (E1731), with or without a dependency. Under `relate --vary grant=dist`,
opaque results agree and diverge on the tested seeds as the same Int draw does,
so the comparison keys them by structure (without a policy the divergence
message shows that structure, as run-transcript-v1 messages do, §2.4); under
an observation policy they are the unsupported opaque kind and the runs cannot
be called equal (E1007), while the same policy compares the Int draw. The host
session test now pins the decoder's own opaque refusal by its cause, the
worker's signature refusal has a control run, and the reader's eval-less
refusal is checked by its cause. The source inventory is now `1246 / 84 / 57`.

Release process, first part. GM12B no longer runs on `release/**` pushes:
release branches are only pull-request heads into `main`, and their pull
requests always rerun the proof, so a release head gets one run instead of
two. Release Evidence groups manual dispatches by the ref they reproduce,
checks out exactly the pushed commit on a push, and cancels only the stale
head of a `release/**` branch. A `jacquard-core-*` tag push reuses an earlier
successful reproduction of exactly the tagged commit and base, found by a
marker artifact whose producing run must be this workflow, started in this
repository by a push of the tagged commit to a release branch, and
successful; a manual dispatch is never reused
(`scripts/release/find-prior-evidence.sh`, pinned by
`release-evidence-reuse.t`). `docs/ci-cd.md` gains a release procedure. The
source inventory is now `1246 / 85 / 57`.

Abstract-types hardening, seventh part. A root project that runs an entry may
rebind prelude constructor names as its own opaque types, as its library check
and the decision record already allowed: the entry check no longer re-reports
clashes between the composed library's constructors and those of its
dependencies or the prelude, which the library check has already judged, and
still refuses an entry's own constructor that collides with a visible one
(E1731). `opaque-matrix.t` now runs such a root against a dependency on both
engines, and on the interpreter without one, and shows that the dependency's
code and the builtins it calls still return prelude values beside the root's
sealed ones. E1731 names the
root's own constructors as `of this project`. The source inventory is
unchanged at `1246 / 85 / 57`.

Release process, second part. The demos Release Evidence reproduces now come
from one list, `scripts/release/run-demos.sh`, which the CI development gate
also runs after the full test suite, so a broken demo fails its pull request
instead of the multi-hour release run; the release transcripts keep their
names. Release Evidence looks for a prior pass only on a tag push, never on a
manual dispatch from a tag, whose `ref` input may name other code. The reuse
finder no longer expands run ids as file name patterns, and its cram refuses
40-character commit and base names that are not lowercase hex. The concurrency
comment and `docs/ci-cd.md` now say that a cancelled stale release head can
still be tagged, and its tag then reproduces in full unless another successful
release push run of the same commit left a marker. The source inventory is
unchanged at `1246 / 85 / 57`.

Release process, third part. Release Evidence now runs its reproduction as
four parallel jobs instead of one serial pass: `scripts/release/reproduce-0.3.sh`
takes `JACQUARD_RELEASE_STAGES` (`core`, `gm12b`, `native-clang`,
`native-gcc`; unset runs everything, as before), and every stage first checks
the clean checkout, the manifests and the historical publications and builds.
An `Identify candidate` job settles the commit and base once and, on a tag
push, looks for a reusable pass; it alone holds `actions: read`. Each stage
checks out exactly that commit and uploads its own transcripts. The required
`Reproduce 0.3 evidence` job passes only when a pass is reused or every stage
passed, runs and fails in a cancelled run instead of being skipped, and only
after a full pass uploads the marker a tag push reuses. No
evidence step is added or removed. The source inventory is unchanged at
`1246 / 85 / 57`.

Release process, fourth part. The published 0.3 documents are frozen at
`jacquard-core-0.3.0`: `docs/release/0.3/DECISION.md`, `EVIDENCE.md` and
`SLICES.md` are restored to their tag bytes, and their inventory is pinned at
`1194 / 78`, as 0.2's is. The work merged after the tag moved from the 0.3
slice log into this one, and the live inventory and the next release's upgrade
notes (including E0811 for undeclared field type variables) are in
`README.md` here. `scripts/release/check-frozen-releases.sh` refuses any change
to the 0.2 or 0.3 documents since their tags; the development gate and Release
Evidence run it, and Release Evidence now verifies the 0.3 manifest at its tag.
The release procedure says how the next release freezes its own documents. No
tests or cram files are added: the source inventory is unchanged at
`1246 / 85 / 57`.
