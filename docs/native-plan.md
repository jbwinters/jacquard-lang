# PF.3: the native compiler — execution plan

Status: ACTIVE (owner decision 2026-07-05: build native compilation now; the
trigger-gating in docs/perf-vm-decision.md governed interpreter work and does
not apply to this program of work). This plan turns docs/native-compilation.md's
four pillars into twelve ordered tasks (task-master 65-76), each specified so
an engineer new to the codebase can execute it, each with a checkable
definition of done. Task 63 is superseded by this plan.

Read first: docs/SKILL.md (the language), docs/native-compilation.md (the
design and its measured phase results), docs/perf-vm-decision.md (why the
interpreter rungs were declined — the ~16ns/node floor is the baseline this
compiler is judged against).

## Architecture, fixed up front

- **Whole-program ahead-of-time compilation.** A new `jacquard build FILE.jqd
  -o OUT` command loads the prelude and the file into a store, typechecks,
  walks the reachable dependency DAG from the top-level expressions, emits one
  C compilation unit per store declaration, compiles with the system C
  compiler, and links a small runtime library into a standalone executable.
- **Per-declaration units cached by content hash** (pillar 4). One C unit
  per store DECLARATION, filename the declaration hash; a multi-member
  defterm group is one unit containing all its members (intra-group
  references become direct static calls inside the unit, which is also what
  makes the group's mutual-recursion cycle a non-issue — the members are
  emitted together as immortal statics). Each member exports a symbol named
  by its member hash for cross-unit calls. An unchanged declaration is never
  re-emitted or recompiled. The cache directory carries an emitter version
  stamp; bumping the emitter invalidates everything.
- **The interpreter stays.** It is the reference engine, the dev tool, and
  the home of everything the compiler refuses. Nothing in this plan touches
  interpreter semantics; `dune runtest` stays green untouched throughout.
  `jacquard test` (Warp discovery, the semantic cache, coverage) and
  `jacquard tiers` are interpreter tooling and stay so — this plan compiles
  program execution, not the toolchain.
- **Bit-identical or red.** The acceptance mechanism for every task is
  differential: a native-eligible program must produce byte-identical stdout,
  stderr, and exit status to `jacquard run`. The eligibility set grows task
  by task; divergence anywhere in it fails CI.
- **Eligibility ladder.** Task 67 compiles pure programs only and refuses the
  rest with a clear diagnostic. Each effects task widens the set. Three things
  stay refused indefinitely, with pinned error messages: `eval` (requires the
  interpreter tier), `code.of-text` (requires the reader), and `--dry-run`
  (an interpreter dev tool). This matches the design doc's slow-set and
  claim-boundary sections.
- **Toolchain: clang first.** v1 requires clang (for `musttail`); gcc and
  platform portability land in task 76, not before.
- **Process.** Every task follows the repo workflow: dev gate green
  (`dune build @all && dune runtest && dune fmt`), a fresh reviewer agent
  pass and a separate sign-off agent pass before the task is marked done,
  commits in coherent chunks. New CI legs are added in task 74 and must stay
  green from then on.

## Value representation (used by every task; decided here once)

`jq_value` is a tagged 64-bit word:

- LSB 1: a 63-bit integer, `(n << 1) | 1`. Jacquard ints are 63-bit exactly
  like OCaml's, so overflow semantics match by construction. Arithmetic uses
  the standard tagged formulas (`add: a + b - 1`, `sub: a - b + 1`,
  `mul: (a >> 1) * (b - 1) + 1`, etc.); division by zero must reproduce the
  interpreter's exact runtime error (read src/runtime_err.ml and the `div`
  native in src/prelude.ml for the message and exit code 2).
- LSB 0: a pointer to an 8-byte-aligned heap block.

Block layout: an 8-byte header `{ uint32 rc; uint8 tag; uint8 flags;
uint16 n }` followed by `n` payload words. `n` is always a WORD count and
is a representation invariant (arity limits are 65535, enforced by clean
aborts, never silent truncation); TEXT keeps its byte length in payload
word 0 (with `n` capped at 0 for texts past 65535 words — the free walk
never reads TEXT's `n`), and HASH is a fixed 32 bytes. The runtime is
64-bit only, statically asserted. Tags: `TUPLE`, `CON` (payload word 0 holds the constructor ordinal
and type id; remaining words are fields), `TEXT` (immutable UTF-8 bytes),
`REAL` (boxed double), `CLOSURE` (word 0 code pointer, word 1 arity and
self-slot index, remaining words captured environment), `CODE` (a boxed form
tree), `RESUME`, `HASH` (32 bytes), and three tags for the first-class
callables that circulate even in pure code: `CONSTRUCTOR` (an unapplied
constructor value — `(var some)` passed to a fold), `OP` (a first-class
effect operation value; referencing one is pure, applying one performs),
and `BUILTIN` (a primitive passed as a value — `(var add)` given to
`list.fold`). All three are per-declaration constants and compile to
immortal statics. Dictionaries are ordinary `CON`/`TUPLE`
data and need no tag. `rc == UINT32_MAX` is the static sentinel: blocks
compiled into the binary (top-level values, literals, quoted forms) are
immortal and dup/drop skip them.

**The cycle rule.** In dynamically allocated data, the only heap back-edge
is the reference a `let rec` closure holds to itself: validation pins
`let rec` to a single `PVar` bound to a `Lam` (src/kernel.ml), strictness
plus immutability mean every other block references strictly older blocks,
and the interpreter's one mutable cell (the recursive knot, src/eval.ml)
is the only post-construction write in the semantics. Mutual recursion
exists only in top-level defterm groups, which DO form genuine cycles and
are safe for a different reason: they compile to immortal statics. The
rule for the dynamic case: the closure's self-slot is non-owning. This is
a compile-time discipline, not a runtime check — closure construction
stores the self-pointer without a dup, and the free walk skips the slot
(`flags` bit plus the slot index in the closure header identify it).
`jq_dup`/`jq_drop` themselves have no self-slot case and cannot have one;
a `jq_value` does not know where it was loaded from. The slot cannot
dangle because it points at its own block.

---

## Task 65 — Runtime core: tagged values and Perceus RC in C

**Deliverables:** a new top-level `runtime/` directory: `jq_value.h`,
`jq_rc.c`, `jq_alloc.c`, `jq_text.c`, a C test suite under `runtime/test/`,
and a dune rule producing `runtime/libjqrt.a` and running the C tests as part
of `dune runtest`.

**Direction.**
1. Implement the value representation above, plus constructors/accessors for
   every tag.
2. `jq_dup(v)`: increment rc unless int or static. `jq_drop(v)`: decrement;
   at zero, free the block after dropping its fields — MUST use an explicit
   heap-allocated worklist, not C recursion (a 10M-element list drop must
   not grow the C stack), and the walk skips a closure's self-slot (the
   compile-time non-owning discipline from the cycle rule; identify it by
   the flags bit and slot index).
3. `jq_drop_reuse(v)`: when rc is exactly 1, detach the block and return it
   for same-size reuse; otherwise drop and return NULL. This is Perceus's
   reuse token (task 68 consumes it).
4. Allocation is plain `malloc`/`free` in v1. Do not build a pool allocator;
   profile first (task 75), optimize after.
5. Text: immutable byte arrays; nothing beyond alloc/length/bytes here (ops
   come with task 66).

**Definition of done.**
- C tests, compiled with `-fsanitize=address,undefined`, cover: rc
  invariants under dup/drop interleavings; reuse token behavior at rc==1 and
  rc>1; a 10M-node list drop with bounded C stack (verify with a small
  `ulimit -s` in the test script); a self-slot closure freed by its last
  external drop; static blocks surviving any number of drops.
- Integer arithmetic parity cases including the edges: 63-bit wrap on
  add/sub/mul, division and modulo including `min_int / -1` (OCaml wraps;
  the C implementation must produce the same value WITHOUT tripping UBSAN —
  do the division on unsigned or guard the one edge explicitly), and
  division by zero reproducing the interpreter's exact error.
- `dune runtest` builds and runs the C tests; the full existing suite stays
  green and untouched.
- ASAN and UBSAN clean on all runtime tests.

## Task 66 — Parity kits: rendering, text semantics, RNG

**Deliverables:** `runtime/jq_show.c`, `runtime/jq_utf8.c`,
`runtime/jq_rng.c`; an OCaml golden generator `test/gen_native_parity.ml`;
golden files under `corpus/golden/native/`.

**Direction.**
1. Port `Value.show` exactly (src/value.ml): ints; reals via `real_repr`
   (src/printer.ml — shortest spelling that reparses to the identical double,
   `%.15g` then widening, with `+inf.0`/`-inf.0`/`+nan.0`); text with
   `escape_text`'s escapes; tuples `(a, b)`; constructors `name` /
   `name(args)`; the placeholder forms `<closure>`, `<constructor f/2>`,
   `<op e.op>`, `<builtin n>`, `<resume>`; `VCode` as `(quote <inline form>)`
   — which requires porting `Printer.inline_form` and `scalar_to_string`
   (hash literals print `#<hex>`).
2. Port the UTF-8 semantics pinned by test/test_text.ml: code-point length
   with per-byte counting for malformed sequences (the "emoji length is 2"
   and "malformed utf-8 counts per byte" tests define the contract).
3. Port `Infer_dist.Rng` bit-for-bit (src/infer_dist.ml): same integer
   arithmetic, same stream for a given seed. This is what makes LW seeds and
   `fault.random` reproducible natively.
4. The golden generator emits, from OCaml: a corpus of values rendered by
   `Value.show`, and the first 1000 outputs of the RNG for seeds
   {0, 1, 42, 2^31-1}. A C test binary regenerates both; the test diffs them.

**Definition of done:** parity goldens byte-identical in CI; regeneration is
deterministic; ASAN clean. Note in the code where the C port leans on libc
(`printf` `%g` rounding, `strtod`): real-formatting parity is guaranteed on
the pinned CI toolchain and re-verified per platform in task 76 — it is a
libc property, not a portable one.

## Task 67 — Compiler skeleton: the pure fragment, .jqd to C to binary

**Deliverables:** `src/native/` OCaml library (lowering, emission, driver),
the `jacquard build` subcommand, `test/cli/native.t`, intrinsics inventory
`docs/native-intrinsics.md`.

**Direction.**
1. **IR.** Lower resolved kernel expressions to ANF: every intermediate is
   let-bound; constructs are `Atom` (var/literal/static), `MakeClosure`
   (code label, sorted free-var list, optional self-slot), `ApplyKnown`
   (member hash + args, arity known from the store), `ApplyUnknown` (atom +
   args), `Alloc` (con/tuple), `Proj`, `Case` (sequential clause tests —
   first-match semantics in source order; a failed match falls through to
   the next clause; exhaustion calls `jq_match_fail` with the scrutinee
   rendered by jq_show, reproducing `Runtime_err.Match_failure`'s exact
   text), `Seq`, `Ret`. `Ann` is type-erased — lower the subject. `GroupRef
   i` lowers to a direct reference to the sibling member's static in the
   same unit. No decision-tree optimization in v1 — record it as
   deliberately deferred.
2. **Closure conversion.** Free variables computed per Lam, sorted by name
   for determinism; `let rec` closures get the self-slot per the cycle rule.
3. **Calling convention.** A member of known arity n compiles to
   `jq_value j_<hash12>(jq_rt*, jq_value, ... n args)`. `ApplyUnknown` goes
   through a generic apply in the runtime that dispatches on the callee tag:
   closure (arity check then indirect call — arity mismatch reproduces the
   interpreter's closure-arity error text), builtin (call the intrinsic —
   the interpreter applies builtins as ordinary callees, src/eval.ml's
   VBuiltin case, and higher-order code passes `(var add)` around), 
   constructor value (saturate to a CON block; arity mismatch reproduces
   the interpreter's DISTINCT constructor-arity error text — read the
   VConstructor case in src/eval.ml), op value (performs — unreachable
   until task 70 because eligibility refuses reachable op refs), resumption
   (task 71). Non-applicable values reproduce `%s is not applicable`.
   Payloads for the three static-callable tags: CONSTRUCTOR carries
   {constructor ordinal, type id, arity, name} (name feeds
   `<constructor f/2>` rendering and the arity error); OP carries
   {op hash, effect name, op name} (feeds `<op e.op>` and perform
   dispatch); BUILTIN carries {intrinsic ordinal, arity, name} (feeds
   `<builtin n>` and the intrinsics table).
4. **Tail calls.** Self-tail-calls become loops in lowering (mandatory —
   `list.fold` must run in constant stack natively). All other calls in tail
   position emit `__attribute__((musttail))` returns; v1 requires clang and
   `jacquard build` errors clearly on other compilers.
5. **Intrinsics.** Enumerate every builtin: the 22 markers in
   prelude/04-builtins.jqd plus everything registered in
   `Prelude.wire_builtins` (src/prelude.ml). Produce
   docs/native-intrinsics.md as a checklist table: name, member hash source,
   C function, parity test present. Implement the pure ones (arithmetic,
   comparison, text ops, real ops, pair ops, code structural ops deferred to
   task 73 — listed as refused for now). Every intrinsic gets a one-line
   parity case in the differential corpus.
6. **Quote.** ALL quotes are refused until task 73 (originally only
   spliced ones were): a pure program can print a code value, printing
   needs the form representation and inline printer, and both are 73's.
   Refusing the construct outright keeps 67's eligibility honest.
7. **Driver.** `jacquard build FILE.jqd -o OUT [--allow eff]...`:
   load prelude + file, typecheck (reuse Check). **Eligibility is SYNTACTIC
   over the reachable declaration DAG, not row-based**: a fully-discharged
   handler has an empty row (corpus/valid/to-option.jqd is Pure and contains
   a `handle`), so checking rows would accept programs this task cannot
   lower. Walk every reachable declaration body and every top-level
   expression; refuse with new diagnostic E1101 (exit 1) on any `Handle`
   node, any `Ref` of kind Op, any live-spliced quote, or any
   not-yet-implemented intrinsic — naming the construct, the declaration it
   sits in, and the rung (the parenthetical tracks the frontier: since
   task 71 it reads "native v1 compiles programs without code values").
   Over-refusal is fine in v1; the set shrinks as tasks 70-73 land. Emit reachable declarations into
   `.jacquard-native/<emitter-version>/`, one unit per declaration hash,
   compile only changed units, link `libjqrt.a`.
   **Per-expression semantics in the generated main** (this is what
   bit-identical means for multi-expression files, and `jacquard run`
   interleaves): the driver bakes an array of per-expression records
   {manifest row, checker warnings}; main loops over expressions in source
   order — replay that expression's build-time warnings to stderr (W0801
   renders at run time in the interpreter), check ITS manifest against the
   runtime `--allow` flags (a failure prints E0814's exact message and
   exits 3 AFTER earlier expressions' output has already printed, matching
   run_cmd), then evaluate and print via jq_show, with the interpreter's
   exit-code contract (0 ok / 2 runtime error with the same stderr
   rendering).
   **Recorded parity boundary — warnings from DECLARATION bodies:** the
   interpreter surfaces those lazily with spans pointing into its ephemeral
   store's object files (a random tmp path), so byte-parity on that class
   is unattainable in either direction. Only top-level-expression warnings
   replay; the task-74 harness excludes decl-warning programs via the
   eligibility manifest with this rationale.
8. **Perceus placeholder.** Until task 68 lands, emit naive `jq_dup` on
   every use and `jq_drop` at scope end — correct but slow. Mark the
   insertion points in the IR so task 68 replaces one pass, not the emitter.

**Definition of done.**
- `test/cli/native.t`: builds ≥10 pure programs (corpus/valid pure subset,
  bench/pure.jqd, a pure demo) and byte-compares native stdout/stderr/exit
  against `jacquard run` IN the cram test.
- Rebuild-without-change compiles zero units (pinned by the cram test via
  the driver's "compiled N units" summary line: second build prints 0).
- Refusal diagnostics pinned for: a program with a reachable handler, one
  with a reachable op reference (eval included), and a spliced quote.
- fib 27 native vs interpreter timing recorded in docs/perf-vm-decision.md's
  table (expectation: order of magnitude; no hard gate yet).
- ASAN build of the native cram corpus clean; dev gate green.

## Task 68 — Perceus: ownership-precise dup/drop and reuse

**Deliverables:** the ownership pass replacing task 67's naive insertion;
a leak harness script `scripts/native-leak-check.sh`.

**Direction.** Implement the Perceus insertion rules (Reinking, Xie,
de Moura, Leijen, PLDI 2021, §2.2-2.4) over the ANF IR: each owned binding
is consumed exactly once per path; backwards liveness per branch; `dup` at
extra uses, `drop` at last-use frontiers and at branch entries for bindings
dead in that branch. All intrinsics take owned arguments in v1 (borrowing is
a later optimization; note it in the code). Reuse: a `Case` arm that
deconstructed a unique CON and allocates a same-arity CON uses
`jq_drop_reuse` on the scrutinee and writes into the returned block.

**Definition of done.**
- The entire native corpus runs leak-free under ASAN leak detection (the
  harness runs every native.t program and fails on any leak).
- RSS plateau: the AVL insert battery (a native port of the 10k-insert
  program) shows steady-state memory across 3 consecutive in-process runs.
- Outputs still byte-identical; naive-mode lever (`JACQUARD_PERCEUS=off`)
  retained for differential debugging.
- Benchmark delta recorded: map.set battery before/after reuse.

## Task 69 — Monomorphization by content hash

**Deliverables:** the specialization pass and its cache.

**Direction.** Worklist over `ApplyKnown` sites: when an argument is a
statically-known member `Ref` (dictionaries are ordinary members per SL.2 —
`int.ord`, `text.eq`), specialize the callee: clone its IR with the argument
bound to that Ref, constant-fold field projections of known records so the
dictionary disappears, and emit under the key `spec:<member>:<arg-hashes>`
(the format pillar 3 fixed). Memoize by key — recursion through the same key
terminates. Unknown dictionary arguments keep the generic path from task 67; the
JACQUARD_SPEC=off lever preserves it wholesale for differential runs.

**Definition of done.**
- The erasure is proven STRUCTURALLY, pinned by grep in the cram test: the
  specialized sort unit calls the comparator intrinsic directly and contains
  zero generic applies. The original 3x wall-clock gate encoded a wrong
  prediction — measured, the erasure is complete but saves ~3% on a 200k
  sort, because merge sort is allocation-dominated and the generic dispatch
  was already cheap (the same lesson that retired PF.2's interpreter rungs).
  Measured numbers recorded in docs/perf-vm-decision.md.
- Second build hits the spec cache (0 units compiled), pinned in cram.
- Outputs byte-identical with and without `JACQUARD_SPEC=off`.

## Task 70 — Effects I: handler runtime, tail-resumptive and root grants

**Deliverables:** `runtime/jq_effects.c` (handler stack, perform),
root-grant implementations (console, clock, fs, net), build-time eligibility
widened to grant-only and tail-resumptive programs.

**Direction.** (As built; the deltas from the original sketch are noted.)
1. **Handler stack, honestly dynamic in v1.** A per-run stack of
   `{op ordinal, clause closure}` entries — one per OP CLAUSE, not per
   handler, which makes nearest-cover search a single field compare;
   `handle` pushes its clauses, scope exit pops them (structured, balanced
   by the compiled construct). Perform searches top-down for the nearest
   cover — exactly the interpreter's nearest-handler semantics. The parity
   subtlety the interpreter forced: a clause BODY runs against the
   continuation OUTSIDE its handler (src/eval.ml runs obody with the outer
   frames), so jq_perform hides the stack slice [match .. top] for the
   duration of the clause call and restores it after — a handle pushed
   inside the clause lands at the truncation point. Static evidence-vector
   indexing remains an optimization to add only if the dynamic search shows
   up in benchmarks.
2. **Op ids** are dense ordinals assigned at link time over the program's
   reachable operations (finer than the sketched per-effect ids, and what
   the grant table and metadata table index by).
3. **Clause discipline is decided at compile time** using the existing
   classifier (src/tier.ml `discipline`): a TailResumptive clause compiles
   to a plain function the perform site calls directly — its `resume(x)` is
   the return path; no continuation exists. The handle body compiles as a
   0-arity thunk so the push/pop stays structured around one call. Root
   grants are runtime C functions with the same shape, ported byte-for-byte
   from Prelude.grant: console (print → fwrite, read-line with EOF as ""),
   clock (now → ms since epoch, sleep → nanosleep), fs (read/write/list-dir
   via stdio + dirent, io failures rendered as Runtime_err.Io over
   Sys_error's "<path>: <strerror>"). net stays refused in v1 binaries —
   granting it is E1103 up front, never a silent no-op. Aborting, OneShot,
   and MultiShot clauses make the program ineligible until task 71.
4. **Manifest per expression.** Task 67's per-expression records carry each
   top-level expression's row; `--allow` flags are parsed at runtime; a
   missing grant reproduces E0814's exact message and exit 3 at that
   expression's turn — earlier expressions' output has already printed,
   exactly as `jacquard run` interleaves checking with evaluation. Two
   parity traps, both found by byte-comparison and both load-bearing:
   the manifests must be harvested from a SECOND run-alike checker context
   (the loader's eager decl checking seeds Check's origin map in a
   different order than run_cmd's lazy checking, and E0814's "performed
   via ..." origin must match byte-for-byte), and the generated main must
   fflush(stdout) after each expression's value print (the interpreter's
   print_endline flushes; without it a later expression's stderr overtakes
   earlier stdout in a merged capture).
5. Pure code containing `handle` expressions: the region under the handle is
   compiled in effectful style even though the enclosing function is pure —
   lowering decides per region, not per function. (Phase 2's experiment
   established this shape; see docs/perf-vm-decision.md.)

**Definition of done.**
- demos/word-count.jqd builds and runs natively byte-identical to the
  interpreter, including the ungranted-refusal path (exit 3, same stderr).
- A console/clock/fs golden set in native.t (hello, timed loop with
  clock.fixed-style in-language handler if tail-resumptive, file round-trip
  under a temp dir) — all byte-identical.
- Unit tests for handler-stack push/pop/nesting and nearest-match semantics.
- Eligibility errors for still-refused disciplines pinned.

## Task 71 — Effects II: capturing and multi-shot continuations

This is the hardest task; budget accordingly.

**Deliverables:** frame-based lowering for capturing code; continuation
capture, resume, and copy-on-resume in the runtime.

**Direction.**
1. Functions (and handle regions) whose clauses may capture — everything
   task 70 refused — lower to explicit-frame style: locals live in a
   heap-allocated frame; frames chain; the chain is the continuation. This
   reimplements the interpreter's frames-as-data discipline in generated C
   for exactly the code that needs it; pure-tier calls made from inside
   remain direct C calls.
2. **Capture** at a perform reaching a capturing clause: slice the chain up
   to and including the handler frame (interpreter semantics: deep handlers,
   the resumption includes the handler), `jq_dup` every value the slice
   references — the dup-on-capture rule recorded in
   docs/native-compilation.md's phase 3 section.
3. **Resume**: copy the captured frame chain (copy-on-resume — the captured
   original stays immutable so a second resume starts from the same state;
   this is what makes multi-shot correct), dup the referenced values, and
   continue execution at the recorded code position (each frame stores a
   function pointer + resume-point index; emitted functions switch on the
   index — standard one-pass CPS state machines).
4. Aborting clauses are capture-and-drop in this task (correct first); the
   no-capture unwind optimization is a recorded follow-up, not v1.
5. Two subtleties the interpreter pins and a first implementation gets
   wrong: (a) an op CLAUSE BODY runs against the continuation OUTSIDE the
   handler (src/eval.ml's perform: `SEval (.., obody, outer)`), so a
   perform inside a clause body escapes outward, never back into the same
   handler; (b) frame-chain ownership — dropping a resumption value drops
   its captured chain's references, and an aborting clause that never
   resumes must therefore leak nothing (the leak harness will catch this,
   but design the ownership story up front, not after).
6. The interpreter's handler semantics are the spec, but the OCaml test
   suites (test/test_handlers.ml, test/test_gauntlet_handlers.ml) are NOT
   directly portable: their harness uses test-only OCaml builtins (bump,
   note, pick) and asserts on OCaml refs, not stdout. Instead, WRITE new
   standalone .jqd differential programs, one per semantic case, that make
   each guarantee observable on stdout — exact effect counts become printed
   values via in-language state/emit counters (e.g. the multi-shot
   exact-count case prints the counter; byte-comparison then IS the
   exact-count assertion). Keep the mapping table (OCaml test -> .jqd
   program) in the test directory so coverage is auditable.

**As built (task 71 delta log).** The mechanism is return-unwinding
(setjmp was rejected: it skips cleanups mid-stack and fights the ASAN
gate): jq_perform matching a CAPTURING clause records the pending capture
and returns a JQ_SUSPEND sentinel; every frame-style activation between
the perform and the covering handle saves its live locals into a heap
JQ_FRAME (slots are borrowed mirrors of the C locals until the suspension
abandons them — ownership transfers without touching a count) and
propagates the sentinel; the jq_handle2 dispatch slices rt->ks (the frame
stack, the runtime image of the interpreter's kont) into a JQ_RESUME and
runs the clause against the outer continuation. Resume clones the chain
(copy-on-resume, dup per slot) and re-runs it with proper C nesting, so
handler-entry bookkeeping stays structured and the handler frame re-runs
the ret clause per resumption. Which fns are frame-style is a syntactic
fixed point over the NIR after monomorphization: perform/handle/unknown
apply directly, known calls to framed members transitively — tops and
const initializers stay direct because a capture always resolves inside
its own expression. Frame-style fns run the NAIVE RC discipline (the
move/Drop bookkeeping does not model abandonment), which costs the AVL
battery its reuse (~10ms -> ~30ms, still ~70x over the interpreter);
recorded for task 75's measurement rather than optimized here. Tail calls
never save frames — the sentinel passes through their returns. Capturing
clauses lower as plain lambdas with the resumption appended as the last
parameter; a fn framed only through tail calls emits no resume machinery.
The escaped-resumption gauntlet case needs a recursive step type to be
typeable at the surface (the answer type recurs in the resumption's
codomain); the decl-body isolation case has no twin — E0815 refuses
effectful decl bodies before either engine runs. support/pmf came forward
from task 72 (the enum handler reaches them).

**Definition of done.**
- Every handler-gauntlet semantic case, rewritten as a standalone .jqd
  program per direction 6, runs natively byte-identical (multi-shot choose
  collecting both branches; thrice; escaped resumption used twice; nested
  same-op shadowing; return clause per resumption; clause-body perform
  escaping outward; abort skipping pending argument evaluation; state.run
  in its state-passing style; abort/throw/emit batteries) — with the
  mapping table showing every OCaml gauntlet case has a native twin.
- demos/m1.sh entirely native-identical (fact, choose, gated eval refusal —
  the eval leg stays a refusal, pinned).
- The in-language enumeration handler (prelude/07-enum.jqd) produces
  byte-identical posteriors natively on the m3 model.
- ASAN/leak clean across all of it (capture/resume is where RC bugs live —
  the leak harness from task 68 must cover every gauntlet program).

## Task 72 — Dist, world, and replay parity

**Deliverables:** native `dist.sample-lw` driver, seeded fault machinery,
record/replay codecs, infer stub with content-addressed cache.

**Direction.** Port the native drivers that live in OCaml today:
`dist.sample-lw` (using task 66's RNG — LW seeds must reproduce),
`fault.random` seeding, the record/replay codec builtins, the infer stub
with its cache-dir behavior including the exact `infer-cache hit/miss <key>`
stderr lines. The in-language world handlers (fs.in-memory, clock.fixed,
console.scripted) already compile via task 71; this task is about the
builtin/root surface. `--dry-run` stays interpreter-only; `jacquard build`
rejects it with a pinned message.

**Definition of done:** demos/m3.sh fully native-identical (enumerate and
lw legs, exact seeds — including the posterior table's exact float
formatting, which src/infer_dist.ml renders with fixed precision; port that
rendering, do not reinvent it); the replay strict/loose cases and the
run-twice-byte-identical DST case native-identical; fault.random
seed-deterministic natively with the same streams.

**As built (task 72 delta log).** Three boundaries the DoD wording did not
anticipate, found during the port and recorded rather than papered over:
(a) the `%.6f` posterior table is `jacquard infer` CLI tooling —
`show_posterior`'s only callers are the two infer subcommands, no builtin
reaches it, so it is unreachable from any compilable program; the
buildable m3 parity target is the builtin output (the weighted
`list (pair a real)` through `dist.enumerate`/`dist.sample-lw`, rendered
by the already-ported real_repr), pinned as gauntlet twins g22/g26.
(b) The replay strict/loose cases are built on the `code.*` builtins
(codec.encode reaches code.form and friends), which are task 73's form
representation and printer — those twins land with 73. DST and
fault.random need neither and are pinned (g23/g24). (c) The infer stub
grant is ported (both prompt shapes, byte-exact); the content-addressed
completion cache needs to READ its readable entry format back (a reader
port, task 73's territory), so native binaries reject `--infer-cache`
with an up-front E1103 instead of silently not caching. Also as built:
`dist.sample-lw` isolates each run against an empty in-language handler
stack (the interpreter drives a fresh state machine per model run) and
renders root-reaching ops with the "(not handled during inference)"
pseudo-effect; the root sampler seeds from `--seed` (both spellings) or
OS entropy, exactly one jq_rng_float per draw with no split; and the DST
battery exposed a real chain-depth bug in run_from (un-entered frames
were re-pushed above their inner extent's frames on suspension —
fixed, unit-tested, and pinned as g25).

## Task 73 — Quote, splices, and structural code ops

**Deliverables:** runtime form representation, splice substitution,
the structural code intrinsics, the canonical inline/full printer in C.

**Direction.** Forms compile to static CODE data; live splices evaluate
left-to-right and substitute exactly as src/eval.ml's `substitute_splices`
does. Scope marks need NO parity work: they live in meta, `inline_form`
never prints meta, and `code.eq?` ignores it — so the interpreter's global
counter (src/eval.ml scope_counter) has no observable native counterpart to
replicate; skip it entirely and say so in a comment. Implement
`code.form`, `code.un-form`, `code.eq?` (port `equal_ignoring_meta`),
`code.of-int`/`to-int`, `code.diff` (needs leaf rendering — port the
canonical printer, ~150 lines of src/printer.ml), `code.to-text` (full
printer). `code.of-text` stays refused (it is the reader); `eval` stays
refused with E1102 "eval requires the interpreter tier".

**Definition of done:** the quote corpus and demos/repair.jqd's pure
mutation machinery (mutant generation, prior, rendering — everything except
the eval-driver acts) native-identical; refusals pinned; `Value.show` of
code values byte-identical (this exercises the ported printer).

**As built (task 73 delta log).** A CODE block is one form node: an owned
TEXT head plus (kind, datum) pairs, every datum an ordinary jq_value, so
the free walk and copy-on-resume needed one new case each and no special
RC discipline. Quotes lower structurally: the static payload parts become
immortal nested-static trees (deduped per unit by a serialization key),
live splices lower left-to-right as ordinary expressions — the
interpreter's FQuote order — and plug into compile-time holes, which IS
substitute_splices constant-folded; a splice that performs works because
the splice Lets are ordinary suspendable sites (gauntlet g33). The
runtime splice guard stays for row erasure (e06). Scope marks have no
native counterpart, per the direction: meta never prints and code.eq?
ignores it. The inline printer, scalar rendering, and real_repr live
beside Value.show in jq_show.c; code.diff ports form_divergences with
the prelude's "at path: - a + b" rendering, and code.form re-renders
invalid heads through OCaml's %S escapes. eval renders as E1102 policy
now, quote's old E1101 refusal is a working pin, and the eligible set
grew to 58 (18-quote builds; repair.jqd manifests on its eval acts while
its pure machinery runs as twin g31, extracted verbatim). free_vars
learned that splice expressions read the enclosing scope — a lambda
capturing only through a splice miscompiled without it. Task-73 testing
also surfaced a latent task-69 unsoundness (spec clones baking
recursion-rebound arguments; fixed and pinned as g34, its own commit).
code.of-text stays refused (the reader); --infer-cache stays refused
(the cache entry format needs the reader too).

## Task 74 — The differential harness as CI law

**Deliverables:** `scripts/native-diff.sh`, a "Native parity" CI job,
an eligibility manifest, a fuzz lane.

**Direction.** The script walks corpus/valid, corpus/sigs, demos, and bench:
for each file, if `jacquard build` succeeds, run both engines and
byte-compare stdout and stderr SEPARATELY plus the exit status (a combined
stream would mask interleaving differences under buffering); if it refuses,
assert the refusal is listed in the manifest
(`test/native-eligibility.txt`) with the expected error.
CI runs the harness plus the runtime ASAN tests on every push (clang pinned
in the workflow). Fuzz: reuse the existing qcheck program generators
(test/test_props.ml's generators are the starting point) to generate random
pure programs, run both engines, assert agreement; 1000 seeded cases in a
slow lane (nightly or on-demand target `dune build @native-fuzz`).

**Definition of done:** harness green in CI on the full current eligibility
set; a deliberately-broken emitter change demonstrably reddens CI (do it on
a branch, link the run in the PR); fuzz lane finds no divergence over 10k
local cases before merge.

**As built (task 74 delta log).** The harness walks 62 files: 53 build and
byte-match (stdout, stderr, and exit compared separately, no grants, no
stdin — deterministic on both engines), 9 refuse per the manifest (three
eval programs, two task-73 code-value programs, one unported intrinsic,
and three companion files whose sibling-decl dependence the checker
refuses identically on both engines). The fuzz generator is purpose-built and
typed by construction (the qcheck form generators emit untyped forms, so
the plan's reuse pointer ends at their shrink discipline): seeded kernel
programs over wrapping arithmetic with live zero-divisor error legs,
let/match/lambda/tuple shapes, list.range traffic, and a recursive
countdown that exercises loopification. `dune build @native-fuzz` runs
1000 cases; the executable takes a count and base seed for the bigger
sweeps. The "Native parity" CI job runs the runtime ASAN gate, the
harness, the gauntlet leak battery, and the fuzz lane on every push;
the DoD's two CI runs are on record: the harness green on main
(https://github.com/jbwinters/jacquard-lang/actions/runs/28781079083)
and a deliberate add-as-sub emitter miscompile reddening BOTH the
Native parity job and the dev gate's differential cram on a demo branch
(PR #2, closed unmerged:
https://github.com/jbwinters/jacquard-lang/actions/runs/28781145795).
The 10k-case fuzz sweep before the merge found no divergence. Review
hardening: the walk is a recursive find with a coverage floor (62),
manifest lookups match the path field exactly, and every leg wears a
timeout so a looping miscompile fails instead of hanging the job.

## Task 75 — Benchmarks and the near-C claim, measured

**Deliverables:** `bench/` suite growth (fib, sort, AVL battery, list
traffic, handler state loop, enumeration), hand-written C references
(`bench/ref/fib.c`, `bench/ref/sort.c`), the measured table in
docs/native-compilation.md.

**Direction.** Three columns: interpreter, native, hand-C (where a reference
exists). Fixed machine, fixed flags (-O2), median of 5, startup subtracted.
Update the claim-boundary section with measured factors. The design claims
near-C only for the monomorphized empty-row core: if fib/sort land within
3x of hand C, the claim stands as written; if not, write the gap analysis
into the doc and file the optimization follow-ups (decision trees for
match, intrinsic borrowing, pool allocation) as new tasks instead of
shipping the words.

**Definition of done:** table committed; claim section updated to measured
numbers; every number reproducible by a documented command.

## Task 76 — Portability and hardening

**Deliverables:** gcc support, error-surface audit, docs.

**Direction.** GCC ≥15 uses musttail; older gcc gets the trampoline fallback
for non-self tail calls (implement it now, behind detection). macOS/arm64
build if hardware is available. Full error-surface audit: every
Runtime_err rendering and exit code compared against the interpreter over an
error-case corpus — division by zero, match failure, arity, unhandled op,
non-applicable, observe-at-root (E0904), and the eval-boundary errors;
enumerate src/runtime_err.ml's constructors and cover each one. Re-verify
real-formatting parity per platform (task 66's libc caveat): the
`%g`/`strtod` round-trip must be golden-tested on every toolchain this task
adds. Stack/frame limits configurable via env var. Docs: README
"Native compilation" section, SKILL.md CLI surface, toolchain requirements,
`jacquard build --help`.

**Definition of done:** the differential harness green under both clang and
gcc on linux x86_64; error-corpus parity pinned in cram; docs updated; the
standard review and sign-off pass, as for every task above.

**As built (task 76 delta log).** gcc is accepted alongside clang: musttail
comes from clang (any) or gcc 15+; older gcc compiles the identical C with
plain calls at non-self tail sites, so tail chains consume stack frames
bounded by the same 1 GiB program stack (JACQUARD_STACK_MB) that already
bounds non-tail recursion — the harness and the runtime gate are green
under gcc 13 with that boundary, and the true trampoline fallback is filed
as task 83 rather than built speculatively (loopification already
covers every self tail, and no corpus program tail-chains past the stack).
[Superseded: task 83 later built the trampoline — see its as-built below —
so the stack-bounded boundary is gone and tails are O(1) on every
toolchain.]

**As built (task 83 delta log, follow-up).** The trampoline landed as two
macros keeping the emitted C identical across toolchains: JQ_TAIL_RETURN
musttails where the toolchain can and otherwise stashes {fn, clo, args}
in rt and returns the JQ_TAILCALL sentinel; JQ_HOP is identity under
musttail and otherwise drives the stashed chain in a loop
(jq_tc_stash/jq_tc_drive, jq_frames.c). Every non-tail call site hops:
emitted BCallKnown/BCallUnknown results and top-level assign-tails, plus
the runtime's own fn-pointer boundaries (call_n, run_from's re-entries,
the effects clause call, the LW thunk apply) — the runtime drives
unconditionally, one dead compare per call under musttail. The proof is
g30-deep-mutual-tail: a 12M-deep even/odd chain (past the old ~10M
SIGSEGV point) runs byte-identical on both toolchains, holds on an
8 MiB stack, and is clean under gcc ASAN; the runtime C tests now drive
their direct jq_apply results like every other C caller, which the gcc
ASAN leg enforces: an undriven sentinel strands the owned value whose
only reference sits in the stash, and the battery reports the leak.
clang codegen and benchmarks are unchanged (the hop is identity); gcc
runs the driver loop and stays green across the harness.
The error-surface audit over src/runtime_err.ml's constructors, with where
each is pinned:

| constructor | native reachability | pin |
| --- | --- | --- |
| Arithmetic | div/mod by zero; LW sample-count and E0901 | check.sh fatal modes; native-effects.t |
| Io | fs grant failures ("io error: path: strerror") | native.t fsmiss |
| Unhandled | ungranted grantable ops are E0814 at the manifest first; the runtime rendering fires for hidden-handler inference runs and is unit-pinned | check.sh unhandled-op; native-effects.t lw-outer-op |
| Observe_at_root | --allow dist observe (E0904; E0902-flattened inside LW) | native-effects.t |
| Match_failure | REACHABLE via row erasure (an op payload type does not flow to its handler, docs/stdlib.md — a handler can resume with a value the site's exhaustive match never expected); also unit-pinned defensively | gauntlet e04; check.sh match-fail |
| Arity | REACHABLE via row erasure (a smuggled closure of the wrong arity) — review round 1 corrected the first draft's "typed away" claim | gauntlet e03 |
| Type_error | REACHABLE via row erasure, both intrinsic and grant legs; the probe caught a live wording divergence in text.concat (the interpreter's text2 wrapper uses the generic rendering), fixed and pinned | gauntlet e02; native-effects.t erasure-grant |
| Unresolved | check-time E0301 on both engines | native-eligibility.txt companions |
| Eval_error | interpreter-only: eval never compiles (E1101) | native.t, native-effects.t |

Real-formatting parity re-verified per toolchain: runtime/check.sh's task-66
parity kit (show/rng/utf8 goldens, the %g/strtod round-trip) runs under both
compilers in CI's toolchain matrix. macOS/arm64 stays unexercised — no
hardware in this environment; the header's detection is arch-independent
and the boundary is recorded here rather than claimed tested.

---

## Order and parallelism

65 → 66 → 67 form the spine. After 67: 68, 69, 73 can proceed in parallel;
70 → 71 → 72 is the effects sequence and the critical path; 74 starts as
soon as 67 lands and ratchets with every task; 75 needs 68+69+71; 76 closes.

On sizing: the design doc's original order-of-magnitude figure for a native
backend was 2-3 months, and review of this plan judged that optimistic —
task 71 (multi-shot continuations as C state machines with copy-on-resume
and RC-correct capture) is the core of Koka's runtime and plausibly costs
2-3 months by itself. Treat 4-6 months of focused work as the honest prior
for the full ladder. Two calibration points are built in: re-estimate at
task 67 (first vertical slice) and again at task 70 (first effects rung),
recording both in this file. The ladder is built so every rung ships alone:
a stop after 69 still yields a compiler for the pure/monomorphized core
with the differential harness guaranteeing it.
