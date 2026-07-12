---
name: jacquard
description: Read, write, run, test, and compile Jacquard programs - the content-addressed, effect-typed research language implemented in this repo. Use when writing or reviewing public .jac programs or bootstrap .jqd fixtures, adding demos or Warp tests, running the jac CLI, debugging effect rows / capability manifests / handlers / Dist models, using the native AOT backend, or touching the OCaml implementation in src/.
---

# Jacquard: the language, fast

Jacquard is a research language for programs written by models and reviewed by
people. Its one design move: **effects, uncertainty, and identity are visible
to tools** instead of hidden in runtime behavior, mocks, logs, or naming
conventions. Concretely:

- A function's signature carries its full story: `(Int, Int) ->{Abort} Int`
  announces the failure path in the **effect row** on the arrow.
- A program's inferred row is its **authority manifest** (checked per
  top-level expression — `main` is a naming convention, not a mechanism); the
  runtime installs root handlers only for effects granted with `--allow`. No
  ambient authority.
- Randomness and conditioning are ordinary effect ops (`sample`, `observe`);
  an inference algorithm is just a handler. Models are code with `{Dist}` rows.
- Definitions are **content-addressed**: hashes are computed with all metadata
  (comments, formatting, spans, provenance) erased. Renames and reformats are
  free; the test cache, semantic differ, and store all key on hashes.

The implementation is OCaml (`src/`), the language ships as a CLI (`jacquard`),
the standard library ("prelude") is written in Jacquard itself (`prelude/`),
and the AOT backend emits C plus the native runtime under `runtime/`. RC1
publishes checksum-verified Linux and macOS binaries with `jac` as the short
command.

## Installation, environment, and CLI

Most users should install the published RC rather than build the OCaml toolchain:

```bash
curl -fsSL https://raw.githubusercontent.com/jbwinters/jacquard-lang/jacquard-core-0.1-rc1/scripts/install.sh | sh
~/.local/bin/jac --version
~/.local/bin/jac run ~/.local/share/jacquard/demos/m1-fact.jac
```

For development, every fresh shell needs the repo-local opam environment;
direct development CLI runs need the prelude:

```bash
eval "$(opam env)"
export JACQUARD_PRELUDE=$PWD/prelude
opam exec -- dune build @all      # build
opam exec -- dune runtest         # full suite (~1 minute; alcotest + qcheck + cram)
opam exec -- dune fmt             # then: git diff --exit-code (the dev gate)
```

`jac` during development is `dune exec jac --`. Public programs use `.jac`;
bootstrap `.jqd` remains the internal/debug and kernel format of record:

```bash
jac run FILE.jac [--allow fs|net|console|clock|eval|dist|infer]... [--dry-run]
jac check FILE.jac [--print-sigs] [--manifest fs,net,console]
jac test TESTS... [--seed N] [--samples N] [--exhaustive] [--budget N]  # .jac or .jqd
                   [--cache-dir DIR | --no-cache] [--allow EFFECT]... [--coverage]
jac infer enumerate MODEL.jac                 # exact posterior (multi-shot enumeration)
jac infer lw MODEL.jac --seed 42 --samples 100000   # likelihood weighting
jac hash FILE.jac                             # canonical HASH_V0 hashes
jac fmt FILE.jac [--write]                    # canonical formatting, comments kept
jac store add|rename ... ; jac diff STORE_A STORE_B   # semantic diff
jac dist-diff MODEL_A MODEL_B                 # posterior divergence between models
jac tiers [FILES...]                          # effect-row tier statistics (PF.2 phase 1)
jac replay LOG PROGRAM [--to N] [--fork 'N=(response 503 "down")']
jac build FILE.jqd -o PROG                    # AOT-compile the kernel carrier
```

`jacquard build` is a real AOT compiler for the `.jqd` kernel carrier. It emits
C for the reachable program, links the native runtime, performs
content-keyed specialization and caching, and delegates machine-code
optimization to clang or gcc (`-O2 -flto`). Tail calls are O(1) stack on both:
musttail where available, a trampoline otherwise. CI byte-compares native and
interpreter stdout, stderr, and exits across the eligibility corpus and runs
ASAN/UBSAN, leak, and 1,000-case fuzz lanes. Capturing and multi-shot handlers,
Dist inference, quotes, splices, and structural code operations compile.
Dynamic `eval` stays interpreter-only (E1102); `--dry-run` and `--infer-cache`
are interpreter tooling and compiled programs refuse them explicitly. The
measured boundary is in `docs/benchmarks.md`; do not generalize those named
results into a production-performance claim.

`jacquard run` loads declarations, then evaluates and prints each top-level
expression in order. Exit codes for `run`: ungranted-effect refusal (E0814)
= 3, runtime failure = 2, ordinary type errors = 1; `check` refusals = 1.

## Physical syntax: two carriers, one kernel

Surface `.jac` is the public authoring syntax documented in
`docs/surface-syntax.md`. It lowers locally to the same 27 kernel forms and has
the same hashes as its paired `.jqd` format-of-record file.

Every form is a triple `(head, meta, args)`. Bootstrap `.jqd` notation is
s-expressions: heads are lowercase `[a-z][a-z0-9-]*`; args are forms or
scalars (int, real, text, symbol, hash); `;` starts a comment; a parenthesized
list with no head symbol (e.g. a `lam` parameter list) parses as a `group`
form. Metadata (spans, comments) never affects a hash — **the metadata law**.

The kernel grammar is 27 forms (authoritative: `docs/ast.md`, `spec/`):

- **expr**: `lit var ref lam app let match tuple handle quote unquote ann`
- **pat**: `pwild pvar plit pcon ptuple pas`
- **type**: `tref tvar tapp tarrow ttuple tforall` (+ `row`/`eref` structures)
- **decl**: `defterm deftype defeffect`

The fixed kernel deliberately has no `if`, statement, list-literal, or pipe
forms. Public `.jac` does have local sugar for `if`/`else`, blocks, lists, and
pipelines; lowering maps all of it onto the 27 forms above without changing
identity. Neither carrier has null, guards, or-patterns, or a module system;
failure is an effect rather than an exception. Do not confuse a missing kernel
form with a missing surface feature, and do not widen either grammar without an
explicit owner decision and evidence update.

## Kernel crash course by example

Everything below is real `.jqd` kernel notation. For normal `.jac` authoring,
read `docs/surface-syntax.md` and the two surface case studies under
`demos/case-studies/`.

```lisp
; application is UNCURRIED: add takes exactly two args (decision D5)
(app (var add) (lit 1) (lit 2))

; functions: params are irrefutable patterns; zero-ary lam/app = thunk/force
(lam ((pvar x) (pvar y)) (app (var mul) (var x) (var y)))

; let carries an explicit rec flag; nonrec is the workhorse.
; sequencing is a pwild let:
(let nonrec (pvar c) (app (var read) (lit "note.txt"))
  (let nonrec (pwild) (app (var print) (var c))
    (var c)))

; match is EXHAUSTIVE (E0813 names the missing witness). No if.
(match (var b)
  (clause (pcon true) (lit 0))
  (clause (pcon false) (lit 1)))

; top-level declarations. A defterm group is one mutually recursive SCC,
; hashed as a unit; recursion (fact calls fact) just works inside it.
; The empty () after the name is the optional type-annotation slot.
(defterm ((binding fact ()
  (lam ((pvar n))
    (match (var n)
      (clause (plit 0) (lit 1))
      (clause (pvar m)
        (app (var mul) (var m) (app (var fact) (app (var sub) (var m) (lit 1))))))))))

; sum types; field labels are optional
(deftype option ((tvar a)) (con none) (con some (field (tvar a))))

; effects: an op whose handler never resumes may promise any result type
(defeffect abort ((tvar a)) (op abort () (tvar a)))

; handlers are DEEP and MULTI-SHOT; ret clause is mandatory; k is an
; ordinary function you may call 0, 1, or N times
(handle (app (var body))
  (ret (pvar x) (app (var some) (var x)))
  (opclause abort () k (var none)))
```

Multi-shot is load-bearing: the enumeration handler resumes once per element
of a distribution's support (see `demos/basics/m1-choose.jac` for the public
version). Tuples: `(tuple)` is unit; `(tuple a b)` pairs. Pattern `(ptuple ...)`
destructures them; `(pcon mk-pair (pvar x) (pvar p))` destructures constructors.

## Effects, rows, capabilities

- Rows live on arrows: `passes? : (Code, List (a, Int)) ->{Eval} Bool`.
  Handling an effect **subtracts** it from the row; row polymorphism
  (`forall a | e. (() ->{Abort | e} a) ->{| e} Option a`) passes the rest through.
- Performing an op is plain application: `(app (var fetch) req)`. There is no
  `perform` keyword.
- `jacquard run` refuses ungranted effects (E0814) *before running the effectful
  expression*; `jacquard check --manifest fs,console` audits without running.
- Attenuation is handler interposition: `fs.read-only` forwards `read`,
  throws on `write`. The wrapped code's row honestly keeps `fs`.
- **Known caveats** (documented, do not "fix" casually):
  - Rows are *name-sets*: effect payload types are erased, so
    `eval : (Code) -> a` and `state.run`'s state type are looser than ideal.
  - `eval`'d code runs at **root authority** — interposed handlers do not
    attenuate `eval-code` payloads; only root grants apply.
  - Top-level defterm bodies must be pure values (E0815); top-level rows are
    CLOSED, so passing a named model where an open row is needed takes an
    eta-expansion: `(lam () (app (var model)))`.
  - `--allow fs` grants the whole filesystem; the grant is the sandbox.

## Dist: probability as an effect

One type, one effect, zero kernel forms (`prelude/06-dist.jqd`):

```lisp
(deftype distribution ((tvar a))
  (con bernoulli (field (tref real)))
  (con categorical (field (tapp (tref list) (tapp (tref pair) (tvar a) (tref real)))))
  (con uniform-int (field (tref int)) (field (tref int))))
(defeffect dist ()
  (op sample ((tapp (tref distribution) (tvar a))) (tvar a))
  (op observe ((tapp (tref distribution) (tvar a)) (tvar a)) (ttuple)))
```

- A model is any `() ->{Dist} a` thunk. Inference = handler choice:
  in-language, `dist.enumerate` (exact, normalized, unmerged) or
  `dist.sample-lw` (seeded likelihood weighting); at the CLI,
  `jacquard infer enumerate` / `jacquard infer lw` (these merge equal outcomes).
  Same model hash, different handler — that's `demos/inference/m3.sh`.
- Merge equal outcomes explicitly: `dist.tally table (app (var mk-eq) (var code.eq?))`
  — tallying asks for its `Eq` honestly.
- Conditioning idiom: `observe (bernoulli w) true` where `w` is 1.0/0.0 —
  impossible branches prune to mass zero (see `demos/inference/synthesis.jac`,
  `demos/tooling/repair.jac`).
- `categorical` weights are **relative**; enumeration normalizes at the end.
- Gotchas: all-branches-impossible yields `+nan.0` weights in-language (the
  CLI's `jacquard infer enumerate` reports E0901 instead); `observe` reaching the
  root is an error (E0904); `uniform-int` enumeration caps at 10000 outcomes.

## Code as data, identity, stores

- `(quote FORM)` yields a `code` value; `(unquote ...)` splices inside quote.
- Runtime reflection builtins: `code.form head children` /
  `code.un-form c -> option (head, children)` (leaves with scalar args —
  `var`, `lit`, `pvar` — return `none`), `code.of-int/to-int`,
  `code.of-text/to-text`, `code.eq?` (metadata-erased structural equality),
  `code.diff` (smallest disagreeing subtrees, as text). A full single-edit
  AST mutation walker in pure Jacquard is in `demos/tooling/repair.jac`.
- Running constructed code is the **eval capability**:
  `(app (var eval-code) c)` needs `--allow eval`; it validates, resolves
  against the store, and runs — at root authority (caveat above).
- `jacquard hash` prints canonical hashes; `jacquard store add/rename` + `jacquard diff`
  show renames as renames and reformatting as nothing. Fixtures, caches, and
  approval workflows (see `demos/worlds/escrow/APPROVAL`) all pin hashes.

## The prelude (stdlib), in rings

`prelude/*.jqd` load in filename order; `prelude/rings.manifest` maps every
name to its ring. Ring rule: a ring references only itself and below.

- **Ring 0 axioms**: `bool option result list ordering`, dictionaries
  (`mk-eq/mk-ord/mk-show`, `eq.fn/ord.fn/show.fn`, `int.eq bool.eq int.ord
  ...`), arithmetic builtins (`add sub mul div mod eq lt`, `real.add
  real.mul real.div real.sub`, numeric `*.gt?/gte?/lt?/lte?`),
  `list.* option.* result.* bool.*`
  (grid: `map filter fold each length ...`).
- **Ring 1 control**: `abort throw state emit fault` + canonical handlers
  (`abort.to-option throw.catch throw.to-result state.run emit.collect ...`),
  bang variants (`option.get! list.head!`).
- **Ring 2 structures**: `pair`, `text.*` (codepoint semantics; `text.eq
  text.ord` live here, not ring 0), `map.*/set.*` (dictionary stored in the
  value), `dist.*` (inference is pure), most Warp assertions, `codec`,
  `fault.all`.
- **Ring 3 world**: `console clock fs net eval infer` (+ `println`,
  `console.ask`, `fs.read-only`, `net.get`), `world-test`/`wcase`,
  `net.record` and `replay.*`. When in doubt, `prelude/rings.manifest` is
  the authority on a name's ring.

Naming: dotted lowercase, subject first, data-first args (`list.sort xs int.ord`);
`?` for predicates, `!` for the aborting/throwing variant; `then` is the
sequencing verb. Dictionaries are explicit values — there are no typeclasses.
`debug.inspect` renders anything as text; debugging only, banned from library
code.

## Warp: the testing story

Read `docs/warp-testing.md`; the API is `prelude/15-warp.jqd` + `16-gen.jqd`.

- One effect: `check` (`check : (bool, text) -> ()` soft, `fail` hard).
  Assertions: `check.true`, `check.eq actual expected EQ SHOW label`,
  `check.some`, `check.fails`, `check.throws`, `check.posterior`,
  `check.same-dist`.
- Tests are ordinary definitions of type `test` or `world-test`; **discovery is
  by checked type** — no annotations, no registry:
  - `(app (var case) (lit "name") (lam () ...))` — row CLOSED at `{check}`:
    hermetic by typechecking. Discharge other effects *inside* the case with
    fixture handlers (`net.scripted`, `clock.fixed`, `fs.in-memory`,
    `console.scripted`, `fault.all`) and enumeration (`dist.enumerate`).
    Note: `eval` has no in-language discharger, so eval-dependent behavior is
    pinned in cram transcripts instead (see `test/cli/repair.t`).
  - `(app (var prop) (lit "name") (lam () ...))` — row `{dist, check}`; the
    generator IS a distribution. `jacquard test` samples (seeded); `--exhaustive`
    proves it over the whole support, budget-bounded. Caveat: the sampling
    driver ignores `observe`; only `--exhaustive` conditions.
  - `group` nests; `wcase` is the world lane (`{check, fs, net, clock,
    console}`), runs only under `--allow` grants, never cached, never retried
    in the hermetic lane.
- The cache is semantic: keys are content hashes, so reformat/rename reruns
  zero tests and editing a dependency reruns exactly its dependents. Use
  `--no-cache` in demos/scripts, `--seed` always for reproducibility.
- A case that makes zero checks WARNs — a test cannot silently assert nothing.
- `jacquard test` selects syntax by extension. Public `tests.jac` files and
  bootstrap `tests.jqd` fixtures use the same type-directed discovery and
  declaration-only E1001 boundary.

## House style and workflow

- **Comment voice**: demos and prelude carry meaning-dense narrative comments
  (thesis first, then mechanics; CAPS for the one load-bearing word). Match
  it. Demo files assembled into Warp suites use a carrier-appropriate driver
  marker (`-- --- demo driver ---` in `.jac`, `; --- demo driver ---` in
  `.jqd`); shell runners strip it with awk to reuse definitions (pattern:
  `demos/case-studies/stormglass/run.sh`,
  `demos/tooling/showcase-warp-tests.sh`).
- **Everything public is pinned**: demo outputs in `test/cli/*.t` cram
  transcripts (run via `dune runtest`; promote intentionally, review diffs),
  hashes in `corpus/golden/` (regen: `dune exec test/gen_goldens.exe`, then
  `gen_prelude_goldens.exe`, `gen_sig_goldens.exe`, `gen_diag_goldens.exe`;
  diffs should be additive), signatures in `corpus/sigs/`.
- Dev gate before any PR: `dune build @all && dune runtest && dune fmt` then
  `git diff --exit-code`. Release-facing changes also run
  `JACQUARD_RELEASE_REF=HEAD JACQUARD_RELEASE_BASE=738dc8e scripts/release/reproduce-0.1.sh`.
- OCaml side: library code returns `('a, Diag.t list) result`; exceptions
  only for internal invariants, prefixed `Bug_`; public functions get doc
  comments; diagnostics get stable `E####` codes cataloged in
  `docs/errors.md` (a test enforces this).
- Guardrails (AGENTS.md): keep the 27-form kernel and the reviewed surface
  boundary. Native AOT and measured optimization already exist; do not add a
  VM/JIT or reopen performance mechanisms without an explicit decision. Macro
  expansion beyond quote/unquote/eval, records, typed staging, continuous
  distributions, language package management, concurrency, and self-hosting
  remain outside the shipped feature set.

## Gotchas that cost real debugging time

- The store name index is keyed by **(name, kind)**: an effect and its op
  legitimately share a name (`abort`, `throw`, `emit`). Never assoc store
  names by name alone. Bare-name precedence when ambiguous: term > con > op
  (W0301 warns).
- Expected-value strings in OCaml tests are `Value.show` renderings
  (`"cons(1, nil)"`, `"true"`), NOT source syntax (`"(var true)"`).
- `jacquard run` can't read process substitution (`<(...)`) — Illegal seek. Use
  temp files.
- `plit` matches int AND text literals (`(clause (plit "operator") ...)` works).
- Ints are native 63-bit and wrap (D2); division truncates toward zero;
  reals are OCaml floats; text is UTF-8 counted in codepoints (not graphemes).
- 8+ structurally identical members in one defterm group can't be canonically
  ordered (E0505).
- In cram tests (`test/cli/*.t`), export `JACQUARD_PRELUDE=../../prelude` and
  remember the sandbox only sees dirs listed in `test/cli/dune` cram deps.
- `jacquard test` accepts `.jac` and `.jqd`, but test files must not contain
  top-level expressions (E1001);
  `--dry-run` refuses programs whose row includes `eval` (E1002).

## Where to look

- Kernel/AST/hashing: `docs/ast.md`, `spec/jacquard-kernel-ast-m0.md`,
  `spec/serialization.md`, `src/kernel.ml`, `src/canon.ml`.
- Runnable intro: `docs/tutorial.md` (10 examples, all pinned in cram).
- Stdlib design + errata: `docs/stdlib.md` (§12 errata is required reading).
- Demo catalog: `demos/README.md` — each demo proves one thesis claim.
- Product-scale examples: `demos/case-studies/release-risk/` and
  `demos/case-studies/stormglass/`, each with surface Warp tests and exhaustive
  world enumeration.
- Errors: `docs/errors.md` (every code, with a trigger example).
- Evaluator/handlers: `src/eval.ml` (CPS, multi-shot); checker/rows:
  `src/check.ml`; inference: `src/infer_dist.ml`; Warp: `src/warp.ml`.
- Native AOT status and measured boundary: `docs/native-compilation.md`,
  `docs/benchmarks.md`, `src/native/`, and `runtime/`.
- Release evidence and claims: `docs/release/0.1/` (CLAIMS.md maps every
  semantic claim to its test).
