# Jacquard Development Plan — M0 through M4

Version 0.1, July 2026. Companion to `jacquard-kernel-ast-m0.md` (the spec) and the whitepaper.
Audience: a junior engineer implementing, plus the owner making the flagged decisions.

Sizes: S is a day or less, M is 2 to 4 days, L is 1 to 2 weeks. Estimates assume one
engineer, OCaml-competent but new to language implementation. Honest total: roughly
60 to 80 working days, about four months solo, before the M4 demos.

How to run this plan: work strictly in phase order, tasks within a phase in numbered
order unless marked parallel-safe. Every milestone boundary is a review gate with a
runnable demo. Nothing merges without its definition-of-done checklist passing in CI.

---

## Global rules

### Definition of done, global (applies to every task on top of its own list)

- [ ] Code builds with `dune build` and passes `dune test` locally and in CI.
- [ ] New behavior has tests written in the same PR; bug fixes add a regression test first.
- [ ] Public functions in touched modules have doc comments stating contract and failure modes.
- [ ] No compiler warnings; `ocamlformat` clean.
- [ ] The conformance corpus (W1.7) still passes; corpus grows if the task added observable behavior.

### Guardrails: explicitly out of scope for this entire plan

Do not build any of the following, even if it seems easy or adjacent. If one appears
necessary, stop and write a one-page decision doc instead.

- Surface syntax design (bootstrap s-expression notation only, defined in W1.2).
- Performance work of any kind. Correctness and clarity only.
- A macro system. Quote, unquote, and gated eval are the whole M-series story.
- Records, row-typed or otherwise, beyond labeled constructor fields.
- Typed staging (`Code a`). `Code` stays untyped this plan.
- Changing curried/uncurried arity conventions (owner decision, expensive after M2).
- Continuous distributions and gradients. M3 is discrete only.
- Package management, self-hosting, ownership/borrowing.

### Decisions needed from the owner (blocking markers appear in tasks)

| ID | Decision | Default the plan assumes | Needed before |
|----|----------|--------------------------|---------------|
| D1 | Hash function constant | SHA-256 via `digestif`, named `HASH_V0`, swappable | W1.5 |
| D2 | Integer semantics | OCaml native 63-bit int; overflow wraps, documented | W2.6 |
| D3 | Text encoding | UTF-8, no normalization | W1.2 |
| D4 | RNG | Seedable splittable PRNG (`splitmix64` port), seed required in CLI | W4.3 |
| D5 | Curried vs uncurried final call | Uncurried (per spec §10.2) | end of M1 |
| D6 | License and repo visibility | Private until M1 demo | W0.1 |

---

## Phase 0 — Bootstrap

### W0.1 Repository scaffold and CI (S)

Create the repo: `dune-project`, `src/` (library `jacquard`), `bin/` (CLI `jacquard`), `test/`
(alcotest), `corpus/`, `spec/` (copy in the M0 spec doc). Add `qcheck` and `digestif`
as deps. GitHub Actions workflow: build + test on push, OCaml 5.1+.

Done when:
- [ ] Fresh clone: `opam install --deps-only . && dune build && dune test` succeeds.
- [ ] CI is green on main with one trivial passing test.
- [ ] `bin/main.ml` prints version string via `jacquard --version`.

### W0.2 Engineering conventions doc (S)

Write `CONTRIBUTING.md`: module naming, error convention (library code returns
`('a, Diag.t list) result`; exceptions only for internal invariant violations, prefixed
`Bug_`), test naming, corpus layout (`corpus/valid/`, `corpus/invalid/`,
`corpus/golden/`), PR checklist mirroring the global DoD.

Done when:
- [ ] Doc exists and CI links to it in the PR template.
- [ ] `Diag.t` module stub exists: severity, span option, code (string like `E0001`), message, hint option.

---

## Phase 1 — Data layer (the spec made executable)

### W1.1 Triple core (S)

Implement the uniform representation from spec §2.

```ocaml
module Meta : sig
  type t  (* string-keyed map to a small value type: span, sym, text, list, map *)
  val empty : t
  val span : t -> Span.t option
  (* reserved keys per spec: span, scopes, name, trivia, origin, doc *)
end

module Form : sig
  type arg = F of t | Int of int | Real of float | Text of string
           | Sym of string | Hash of Hash.t
  and t = { head : string; meta : Meta.t; args : arg list }
  val equal_ignoring_meta : t -> t -> bool
end
```

Done when:
- [ ] Unit tests construct nested forms and inspect them.
- [ ] `equal_ignoring_meta` property test (qcheck): random meta perturbation never affects equality.

### W1.2 Bootstrap notation: reader and printer (M) — needs D3

There is no surface language yet; programs are written directly as s-expression-encoded
triples, extension `.wft`. Pin the notation exactly:

```
form      := ( head arg* )
head      := lowercase symbol matching a kernel constructor: app, lam, lit, ...
arg       := form | integer | real | "text" | 'symbol | #hexhash
```

Meta is never written in source. The reader fills `span` automatically from lexer
positions. Examples that must parse (add to corpus):

```
(lit 1)
(app (var add) (lit 1) (lit 2))
(lam ((pvar x)) (var x))
(defterm ((binding fact ()
  (lam ((pvar n))
    (match (var n)
      (clause (plit 0) (lit 1))
      (clause (pvar m)
        (app (var mul) (var m)
          (app (var fact) (app (var sub) (var m) (lit 1))))))))))
```

Note: bootstrap files use `(var name)` for all references; W1.4 resolves globals to
`ref` forms. Printer emits canonical formatting (2-space indent, one form per line at
depth ≤ 1).

Done when:
- [ ] Reader produces `Form.t` with correct spans; positions verified in tests.
- [ ] Parse errors report line:col and the offending token; 5 golden error tests.
- [ ] Round trip: `print (parse s)` reparses to a form equal ignoring meta; property test over corpus.
- [ ] Corpus gains ≥ 10 valid and ≥ 5 invalid `.wft` files.

### W1.3 Kernel grammar validator and typed AST (M)

Two layers per spec §1: generic triples, and the grammar as a checker plus a typed
OCaml mirror for later passes.

```ocaml
module Kernel : sig
  type expr = Lit of lit | Var of string | Ref of Hash.t * refkind
            | Lam of pat list * expr | App of expr * expr list
            | Let of bool * pat * expr * expr
            | Match of expr * clause list | Tuple of expr list
            | Handle of expr * ret * opclause list
            | Quote of Form.t | Unquote of expr | Ann of expr * ty
  (* pat, ty, decl, and auxiliaries mirroring spec §4 exactly *)
  val of_form : Form.t -> (decl, Diag.t list) result   (* and expr entry point *)
  val to_form : decl -> Form.t                          (* injective, meta-preserving where held *)
end
```

Enforce structural rules from the spec: `Unquote` legal only under `Quote`; `Lam`
params and `Let` binders irrefutable (`PWild`, `PVar`, `PTuple`/`PAs` of irrefutables);
`Let rec` binder is `PVar` with `Lam` value; `Match` has ≥ 1 clause; `Handle` has
exactly one return clause.

Done when:
- [ ] Every one of the 27 forms has ≥ 1 accepting and ≥ 2 rejecting tests (wrong arity, wrong arg sort).
- [ ] Each structural rule above has a dedicated rejecting test with its own `E`-code.
- [ ] `to_form` then `of_form` is identity on the typed AST (property test).

### W1.4 Name resolution (M)

Pass from parsed forms to resolved kernel: locals stay `Var` (lexical scoping over
`lam`, `let`, `match` clause patterns, handler clause params and resume names); free
names look up the store's name index (W1.6) and become `Ref(hash, kind)`, retaining
the original name in meta under `name`. Unknown free name is a diagnostic listing
near-miss suggestions (edit distance ≤ 2).

Circular note: resolution needs the store; the store needs hashes; hashes need resolved
forms. The seam: W1.4 exposes `resolve : Store.t -> Form.t -> (Kernel.decl, Diag.t list) result`
and is tested first against a hand-built in-memory store stub; W1.6 swaps in the real one.

Done when:
- [ ] Shadowing tests: inner `let x` shadows outer; patterns bind in clause body only.
- [ ] Within a `defterm` group, members see each other (self-reference resolves to a group-local marker per spec §6, not a hash).
- [ ] Unknown-name diagnostic includes ≥ 1 suggestion when a near miss exists.

### W1.5 Canonicalization and hashing (L) — needs D1

Implement spec §6 exactly:

1. Erase meta.
2. Locals to de Bruijn indices.
3. `DefTerm` SCC hashed as a unit: canonical member order (serialize each member with
   self-references as bound indices, sort by that serialization, ties broken by full
   bytes), in-group references become `GroupRef i`; group hash = `HASH_V0` of the
   ordered serialization; member hash = hash of (group hash, index).
4. Constructor and op references canonicalize to (decl hash, ordinal).
5. Deterministic byte serialization (length-prefixed, tag bytes per constructor;
   document the format in `spec/serialization.md`).

Done when:
- [ ] Golden hashes checked in for the whole corpus; CI fails on drift.
- [ ] Property: alpha-renaming locals never changes a hash (qcheck renamer).
- [ ] Property: any meta mutation never changes a hash.
- [ ] Permuting the source order of a mutually recursive group's members never changes the group hash (test with a 3-member cycle).
- [ ] Two textually different but alpha-equivalent factorials hash equal (explicit test).

### W1.6 Content-addressed store (M)

On-disk layout: `store/objects/<hash>.wft` (canonical printed form) plus
`store/names.wft` (name-to-hash index, the only mutable file). API: `put_decl`,
`get`, `name`, `rename`, `deps` (hashes referenced by a decl), `dependents` (reverse
index, may be computed).

Done when:
- [ ] Put/get round trip preserves hash identity.
- [ ] `rename` changes only `names.wft`; object files byte-identical before and after (test asserts this).
- [ ] `deps` correct on a 3-decl chain; `dependents` inverse of `deps` (property test on random DAGs).

### W1.7 Conformance corpus and harness (S, then ongoing)

A runner that walks `corpus/valid` (must parse, validate, resolve, hash to golden) and
`corpus/invalid` (must fail at the stage named in a sidecar `.expect` file with the
expected `E`-code). Every later phase adds cases; the corpus is the spec's teeth.

Done when:
- [ ] `dune test` includes the corpus runner; a deliberately broken case fails CI.
- [ ] README in `corpus/` explains how to add a case in under five lines.

Milestone gate M0-exec: spec is executable. Demo: add a new tiny decl to the corpus
live; show validation, resolution, stable hash, rename-without-rehash.

---

## Phase 2 — Interpreter (Milestone M1)

### W2.1 Runtime values and environments (S)

```ocaml
module Value : sig
  type t = VInt of int | VReal of float | VText of string
         | VTuple of t list
         | VCon of Hash.t * int * t list          (* type hash, ordinal, args *)
         | VClosure of env * Kernel.pat list * Kernel.expr
         | VBuiltin of string * (t list -> t)
         | VCode of Form.t
         | VResume of resume                       (* filled in W2.4 *)
end
```

Environment: persistent string map. Done when constructors and printers exist with
tests; `Value.show` output is stable (golden).

### W2.2 CPS evaluator core, no effects yet (M)

Frames are data, not host closures; this decision exists so W2.4 can slice the stack.

```ocaml
type frame = FAppFn of ...) | FAppArgs of ... | FLet of ... | FMatch of ...
           | FTupleN of ... | FAnn | FHandle of handler   (* handler in W2.4 *)
type kont = frame list
val step : state -> state    (* small-step; state = Eval of env*expr*kont | Apply of value*kont *)
val run  : Store.t -> Kernel.expr -> (Value.t, RuntimeErr.t) result
```

Covers `Lit Var Ref Lam App Let Tuple Ann` plus `Match` via W2.3. `Let rec` ties the
knot with a mutable closure cell (document it). `Ref` of term kind loads from store and
memoizes evaluated top-level values.

Done when:
- [ ] Factorial (from W1.2 corpus) evaluates: 5 → 120, 0 → 1.
- [ ] Mutual recursion across a `defterm` group works (even/odd test).
- [ ] Left-to-right strict evaluation order proven by a test using a builtin that records call order.
- [ ] Uncovered match yields `RuntimeErr.MatchFailure` with the scrutinee printed (checker will prevent this at M2; interpreter must still trap it).

### W2.3 Pattern matching runtime (S)

`match_pat : Value.t -> Kernel.pat -> env option` covering all six pattern forms;
`PAs` binds and recurses; `PCon` checks type hash and ordinal.

Done when:
- [ ] Table-driven tests: every pattern form × match/no-match.
- [ ] Nested `PAs` inside `PCon` inside `PTuple` binds all names (one deep test).

### W2.4 Handlers and multi-shot resumptions (L) — the riskiest task in the plan

Semantics to implement (deep handlers, spec §5.1 and §7):

1. `Handle(body, ret, ops)` pushes `FHandle h` and evaluates body.
2. Body finishes with value v: pop to `FHandle`, run the return clause with v.
3. Performing an op = `App` of an `Op`-kind `Ref`: walk the kont outward for the
   nearest `FHandle` handling that op's hash. Split the kont: `inner` (frames up to
   and excluding that `FHandle`) and `outer` (the rest).
4. The resumption value captures `inner ++ [FHandle h]` (deep: the handler re-wraps).
   Resumptions are immutable data, so invoking one twice is just reusing the list:
   multi-shot for free.
5. Evaluate the matching op clause in `outer` with op args bound and `resume` bound
   to the resumption.
6. Invoking a resumption with v: prepend its captured frames onto the current kont
   and apply v.
7. No matching handler anywhere: `RuntimeErr.Unhandled(effect, op)` naming the effect.
   This error is the capability story at runtime.

Done when (each bullet is a named test):
- [ ] State effect: get/put handler threads state; program using both returns expected pair.
- [ ] Abort effect: clause that never resumes short-circuits past pending frames.
- [ ] Deep semantics: a second perform inside the resumption is handled by the same handler.
- [ ] Multi-shot smoke test: a Choose op whose handler calls resume with true and again with false, collecting both branch results into a list of length 2 with distinct values. This test is the reason the interpreter is CPS; it must exist and pass before anything else in this task merges.
- [ ] Forwarding: inner handler for effect A, op of effect B performed inside, outer handler for B catches it.
- [ ] Return clause transforms the body value (wrap-in-Some test).
- [ ] Unhandled op at root: error names effect and op, exit code distinct in CLI.

### W2.5 Quote, unquote, Code, gated eval (M)

`Quote` evaluates to `VCode` of the enclosed form with `Unquote` sites replaced by the
form-value of evaluating the spliced expression (splice must evaluate to `VCode`;
anything else is a runtime diagnostic). Hygiene scope-set plumbing is stubbed: reserve
the meta key, generate fresh scope marks on quote, no resolution logic yet (macros are
out of scope; the marks just travel).

`eval` is an op of a builtin `Eval` effect declared in the prelude. The interpreter
ships an eval handler as a builtin that the CLI installs only under a flag.

Done when:
- [ ] Quote of quote nests correctly (structure test on the resulting `VCode`).
- [ ] Splicing a computed form into a quoted `app` produces the expected triple.
- [ ] `eval` on quoted factorial applied to 5 yields 120 under `jacquard run --allow Eval`.
- [ ] The same program without `--allow Eval` fails with the Unhandled error from W2.4. This pair of tests is the first capability demo and gets a named spot in the corpus.

### W2.6 Prelude v1 (M) — needs D2

`prelude/` as `.wft` files loaded into a fresh store: `Bool`, `Option`, `List`,
`Ordering` as `deftype`; comparison and arithmetic as `VBuiltin` terms registered under
hashes; `not`, `and`, `or`, `map`, `fold` written in Jacquard (matches, no `if`, per spec).
Effects declared: `Eval`, `Abort`, `Console` (print op) for demos.

Done when:
- [ ] Prelude loads with zero diagnostics; all prelude hashes golden-pinned.
- [ ] `map (add 1) [1,2,3]`-equivalent corpus program yields expected list value.
- [ ] A program using Console prints only under `--allow Console`.

### W2.7 CLI (S)

`jacquard run FILE [--allow EFFECT]...`, `jacquard check FILE` (grammar + resolution),
`jacquard hash FILE`, `jacquard store add|name|rename`.

Done when:
- [ ] Each command has a happy-path and a failure-path test driving the binary (expect-style).
- [ ] Exit codes: 0 ok, 1 diagnostics, 2 runtime error, 3 unhandled effect.

Milestone gate M1. Demo script (checked into `demos/m1.sh`): run factorial; run the
multi-shot Choose program; run eval-gated program with and without `--allow Eval`.
Owner decision D5 (curried question) closes here.

---

## Phase 3 — Type and effect checker (Milestone M2)

### W3.1 Types, rows, unifier (L)

Internal type representation with mutable unification variables and levels for
generalization. Effect rows: normalized as (sorted set of effect hashes, optional row
variable). Row unification: cancel the intersection; a closed row absorbs remainder
only if empty; open rows bind each var to the other side's remainder plus a fresh
common tail. Reference: Leijen, POPL 2017, simplified to set semantics (no duplicate
labels). Occurs check on both type and row vars.

Done when:
- [ ] Unifier unit tests: 15+ cases including row cases (closed vs closed mismatch, open absorbs, open vs open fresh tail, occurs failure).
- [ ] Property: unify(a,b) succeeds iff unify(b,a) does, and resulting substitutions agree up to var renaming (qcheck over small random types).

### W3.2 Expression inference (L)

Algorithm W-style inference with `Ann` as a checking anchor (bidirectional lite).
Generalization at `Let` under the value restriction: generalize only syntactic values
(`Lam`, `Lit`, `Tuple` of values, constructor applications of values). Every `App`
unifies the callee's row with the ambient row; `Lam` starts a fresh ambient row that
lands on its arrow.

Done when:
- [ ] Golden elaborated signatures for 20 corpus programs (`jacquard check --print-sigs`).
- [ ] Identity gets `forall a. (a) ->{} a`; a Console-printing function's row shows Console; composition of pure and effectful propagates the row.
- [ ] Value restriction test: `let r = ref-like non-value` does not generalize (encode with a builtin), while `let f = lam...` does.
- [ ] Ann mismatch produces expected/actual diagnostic with both types printed fully elaborated.

### W3.3 Declaration checking (M)

Arity-only kind check for `deftype`/`defeffect` parameters; constructor result types
must be the declared type applied to its vars; op signatures wellformed; `defterm`
group checked mutually with annotations honored as checks.

Done when:
- [ ] Malformed decl corpus cases (wrong arity, unbound tyvar, op returning unbound var) each rejected with distinct codes.
- [ ] Even/odd mutual group checks with and without annotations.

### W3.4 Handler typing (M)

`Handle`: body checked with row = handled effect + delta; handler removes the handled
effect from the outward row. Return clause: binder gets body's type; result is the
handle expression's answer type. Op clause: params per opspec; `resume` has type
`(op result) ->{outer row} answer`; clause body checked at answer type under outer row.

Done when:
- [ ] State handler from W2.4 corpus typechecks; its elaborated signature golden-pinned.
- [ ] Handling removes the effect: a fully handled program's `main` row is empty.
- [ ] Wrong-typed resume argument and wrong-arity op clause each produce dedicated diagnostics.

### W3.5 Exhaustiveness and irrefutability (M)

Maranget's usefulness algorithm ("Warnings for pattern matching", JFP 2007) over the
pattern matrix; specialize by constructor using `deftype` info from the store; literals
treated as infinite types needing a default. Reject non-exhaustive `Match` (error, not
warning, per spec) printing a missing-pattern witness. Reject refutable patterns in
`Lam`/`Let` binders.

Done when:
- [ ] Bool match missing False rejected, witness prints `False`.
- [ ] Nested witness test: matching `Option (Option Bool)` missing `Some (Some False)` prints exactly that.
- [ ] Redundant clause produces a warning diagnostic (code distinct from errors).
- [ ] `PLit` scrutinee without catch-all rejected; with `PVar` accepted.

### W3.6 Root capability manifest (S)

`jacquard run` computes `main`'s inferred row and refuses to start unless every effect is
covered by `--allow` grants (which install the builtin root handlers). `jacquard check
--manifest net,console` typechecks against a granted set without running.

Done when:
- [ ] The hostile demo passes: a function performing Net (declared in prelude, handler
      is a stub) makes any program calling it carry Net in its row; check without the
      grant fails at the type level naming the effect and the call chain endpoint;
      with the grant it passes. This test is Demo 2's core and is pinned in corpus.

### W3.7 Diagnostics v1 (M)

Adopt the rubric that every checker diagnostic answers: what happened, where (span with
source excerpt and caret), why (expected vs actual, elaborated), and one thing to try.
Snapshot-test the exact rendered output of the 20 most common diagnostics.

Done when:
- [ ] 20 golden rendered diagnostics; CI fails on wording drift.
- [ ] Every `E`-code emitted anywhere in the checker appears in at least one golden test (enforced by a coverage check over the code enum).

Milestone gate M2. Demo: elaborated signatures printed for the prelude; the hostile
capability check failing then passing; a non-exhaustive match caught with witness.

---

## Phase 4 — Dist (Milestone M3)

### W4.1 Distribution library and Dist effect (S)

Prelude additions per whitepaper §6: `deftype Distribution a` with `Bernoulli real`
and `Categorical (List (Tuple a real))` (discrete only); `defeffect Dist` with
`sample : Distribution a -> a` and `observe : Distribution a -> a -> ()`. Builtin
`pmf : Distribution a -> a -> real`.

Done when:
- [ ] Declarations load and their hashes are pinned.
- [ ] `pmf` unit tests: Bernoulli and Categorical, including zero-probability values.

### W4.2 Enumeration handler, builtin (M)

Builtin handler installed by `jacquard infer enumerate FILE`: on `sample d`, resume once
per support element, weighting each branch by `pmf d x` (multi-shot doing its job); on
`observe d v`, multiply the branch weight by `pmf d v` and resume with unit; collect
(value, weight) leaves; normalize; print the posterior table sorted by probability.
Weight underflow to exactly 0.0 prunes the branch.

Done when:
- [ ] Two-coins model (observe at least one heads; posterior of first coin) matches the hand-computed exact answer within 1e-9; the expected numbers are written as a comment derivation in the test.
- [ ] Sprinkler-style 3-variable model matches hand-computed posterior within 1e-9.
- [ ] A model with an impossible observation reports an empty posterior with a clear message rather than dividing by zero.
- [ ] Branch count on the two-coins model is exactly 4 (instrumented counter), proving no duplicate resumption.

### W4.3 Likelihood-weighting handler (M) — needs D4

`jacquard infer lw --seed N --samples K FILE`: sample ancestrally on `sample` (single
resume, drawn via seeded RNG), multiply weight on `observe`, run K independent
executions, report normalized empirical posterior.

Done when:
- [ ] Same two models as W4.2: with seed fixed and K = 100000, estimates within 0.01 of exact (tolerances written into the test with the derivation).
- [ ] Same seed twice gives byte-identical output; different seeds differ.
- [ ] The model files are byte-identical between W4.2 and W4.3 runs; the test asserts the hashes match. The model does not change, only the handler: this is the M3 thesis and the test says so in its name.

### W4.4 Stretch: enumeration handler in Jacquard itself (M, parallel-safe after W4.2)

Port W4.2's handler to prelude Jacquard using `Handle`, list ops, and real arithmetic
builtins. Proves handlers-as-libraries.

Done when:
- [ ] In-language handler reproduces W4.2's two-coins posterior within 1e-9.

### W4.5 Demo 1 assembly (S)

`demos/m3.sh`: one model file, `enumerate` then `lw`, transcript checked in.

Done when:
- [ ] Script runs clean from a fresh clone in CI and its output matches the committed transcript.

Milestone gate M3 = Demo 1 (the whitepaper's first falsifiable finish line).

---

## Phase 5 — Tooling (Milestone M4)

### W5.1 Formatter (M)

`jacquard fmt`: canonical printer with trivia preservation, reading comment/whitespace
trivia from meta (extend the W1.2 reader to capture comments `; ...` into trivia).

Done when:
- [ ] Round trip: parse, format, reparse yields equal-ignoring-meta forms AND identical trivia; property test over corpus.
- [ ] Idempotency: formatting a formatted file is a no-op (byte comparison), property test.
- [ ] Comments survive: a commented corpus file formats with every comment retained adjacent to its original node (golden).

### W5.2 Semantic differ (M)

`jacquard diff STORE_A STORE_B` (or two files): classify each named definition as
identical (same hash), renamed (same hash, different name), meta-only, or changed;
for changed, descend the two trees to the smallest disagreeing subtrees and print
them with paths.

Done when:
- [ ] Rename-only change reports exactly one rename and zero content changes.
- [ ] Reformat/comment change reports "no semantic changes".
- [ ] A one-literal edit inside a large function localizes to that literal's subtree (golden output).
- [ ] An edit to a shared helper reports the helper changed and lists dependents via the store's reverse index.

### W5.3 Error message audit (M)

Apply the W3.7 rubric shop-wide, now including runtime and CLI errors. Write
`docs/errors.md` cataloging every code with an example. Rewrite the worst ten
messages found during the audit.

Done when:
- [ ] Every emitted code appears in `docs/errors.md` (enforced by test).
- [ ] Ten before/after rewrites reviewed by the owner; goldens updated.

### W5.4 Docs, examples, CLI polish (M)

`docs/tutorial.md` with ten runnable examples (each a corpus file), `jacquard --help`
per-command help, and a top-level `README` describing the two demos.

Done when:
- [ ] Every tutorial example runs in CI.
- [ ] A new user can go from clone to running Demo 1 following only the README (verified by someone other than the author, checklist signed off in the PR).

### W5.5 Demo 2 assembly (S)

`demos/m4-hostile.sh`: the generated-looking function that attempts Net; `jacquard check`
refusal with the signature printed; the granted run succeeding against the stub
handler; transcript committed.

Done when:
- [ ] Script output matches committed transcript in CI.

Milestone gate M4 = both whitepaper demos green from a fresh clone.

---

## Dependency sketch

```
W0.* -> W1.1 -> W1.2 -> W1.3 -> W1.4 -> W1.5 -> W1.6 -> W1.7
                                 (stub store)      (real store swaps in)
W1.* -> W2.1 -> W2.2 -> W2.3 -> W2.4 -> W2.5 -> W2.6 -> W2.7  [M1]
W2.* -> W3.1 -> W3.2 -> W3.3 -> W3.4 -> W3.5 -> W3.6 -> W3.7  [M2]
W3.* -> W4.1 -> W4.2 -> W4.3 -> W4.5   (W4.4 parallel after W4.2)  [M3]
W4.* -> W5.1 .. W5.5 (5.1 and 5.2 parallel-safe)  [M4]
```

## Risk notes for the implementer

W2.4 is the plan's technical center of gravity; its multi-shot smoke test is
deliberately the first thing to write in that task, and if the frame-slicing design
fights back for more than two days, stop and escalate rather than switching to host
closures (which would silently forfeit multi-shot and sink M3). W3.1's row unifier is
the second hardest piece; the simplification to set-semantics rows is intentional and
documented, and duplicate-label generality is out of scope. Everything else is normal
engineering with unusual test discipline.
