# Weft diagnostic codes

Every diagnostic the toolchain can emit, with an example that triggers it. Codes are
stable: never reused, never renumbered. A test enforces that every code emitted anywhere
in `src/` and `bin/` appears in this catalog.

## Reader (E01xx)

| code | meaning | example |
|------|---------|---------|
| E0101 | unexpected character | `(lit @)` |
| E0102 | unterminated text literal | `(lit "abc` |
| E0103 | invalid escape sequence | `(lit "a\qb")` |
| E0104 | invalid hash literal | `(ref #beef term)` |
| E0105 | malformed number | `(lit 1.2.3)` |
| E0106 | unexpected end of input | `(lit 1` |
| E0107 | bad form head | `(42 x)` |
| E0108 | unexpected `)` | `)` at top level |
| E0109 | integer out of the native 63-bit range | `(lit 123456789012345678901234567890)` |
| E0110 | non-form element in a bare group | `(group 42)` |
| E0111 | invalid quoted symbol | `(var 'Foo)` |
| E0112 | invalid bare symbol | `(var a@b)` |
| E0113 | non-form at top level | `42` |
| E0114 | more than one form where one was expected | two forms passed to a one-form entry point |

## Kernel validator (E02xx)

| code | meaning | example |
|------|---------|---------|
| E0201 | not a kernel form (unknown head in this position) | `(banana 1)` |
| E0202 | wrong arity for a kernel form | `(lit)` |
| E0203 | wrong argument sort | `(lit x)` |
| E0204 | `unquote` outside `quote` | `(unquote (var f))` |
| E0205 | refutable `lam` parameter | `(lam ((plit 1)) ...)` |
| E0206 | refutable `let` binder | `(let nonrec (pcon true) ...)` |
| E0207 | `let rec` binder is not a variable | `(let rec (ptuple ...) ...)` |
| E0208 | `let rec` value is not a `lam` | `(let rec (pvar f) (lit 1) ...)` |
| E0209 | empty `match` | `(match (var x))` |
| E0210 | invalid ref kind | `(ref #... banana)` |
| E0211 | invalid rec flag | `(let sometimes ...)` |
| E0212 | `handle` without exactly one `ret` clause | two `ret` clauses |

## Name resolution (E03xx)

| code | meaning | example |
|------|---------|---------|
| E0301 | unknown name (with near-miss suggestions) | `(var ad)` when `add` exists |
| E0302 | name kind mismatch | `(ann (lit 1) (tref add))` — a term used as a type |
| E0303 | duplicate binding name in a defterm group | two bindings named `f` |
| E0304 | variable bound more than once in one binder group | `(lam ((pvar x) (pvar x)) ...)` |

### Resolution warnings (W03xx)

| code | meaning | example |
|------|---------|---------|
| W0301 | a bare variable is bound across several value kinds; precedence picked one | `(var abort)` when `abort` is both a term and an op — term > con > op |

## Canonicalization and hashing (E05xx)

| code | meaning | example |
|------|---------|---------|
| E0501 | unresolved name reached hashing | hashing skipped resolution |
| E0502 | unbound variable reached hashing | free `(var x)` hashed |
| E0503 | `groupref` outside its group or out of range | `(groupref 0)` at top level |
| E0504 | malformed unquote reached hashing | internal guard |
| E0505 | defterm group too symmetric to order canonically | 8+ identical members |

## Store (E06xx)

| code | meaning | example |
|------|---------|---------|
| E0601 | unknown hash | `weft store name s x 000...0` |
| E0602 | unknown name | renaming a name that is not bound |
| E0603 | corrupt store file | hand-edited `names.wft` or object file |
| E0604 | unnameable target | naming a defterm group's whole hash |
| E0605 | invalid name | `weft store rename s x "Bad Name"` |
| E0606 | store directory does not exist | `weft diff a /nowhere` |
| E0607 | name bound to several kinds; needs --kind | renaming `abort` when it is both an effect and an op |
| E0608 | unknown --kind value | `weft store rename --kind bogus` |

## Prelude and grants (E07xx)

| code | meaning | example |
|------|---------|---------|
| E0701 | prelude directory missing | `--prelude /nowhere` |
| E0702 | prelude name missing or wrong kind | truncated prelude |
| E0703 | effect not grantable | `--allow filesystem` |
| E0704 | store add expects declarations only | an expression in `weft store add` |

## Type and effect checker (E08xx, W08xx)

| code | meaning | example |
|------|---------|---------|
| E0801 | type mismatch (expected vs actual, elaborated) | `(app (var add) (lit 1) (lit "x"))` |
| E0802 | application of a non-function | `(app (lit 3) (lit 1))` |
| E0803 | arity mismatch (call, op clause, resumption) | one-parameter lambda applied to two |
| E0804 | annotation mismatch | `(ann (lit 1) (tref text))` |
| E0805 | reference kind mismatch or unknown hash | `(groupref 5)` outside a group |
| E0806 | constructor pattern arity | `(pcon some)` with no argument |
| E0810 | type constructor arity (kind) error | `(tapp (tref option) a b)` |
| E0811 | unbound type or row variable | `(tvar zz)` in a declaration |
| E0812 | unbound variable in an effect op signature | `(op o () (tvar zz))` |
| E0813 | non-exhaustive match (with witness) | bool match missing `false` |
| E0814 | ungranted effect in the program manifest | running a printing program without `--allow console` |
| E0815 | effectful top-level definition body | `(defterm ((binding x () (app (var print) ...))))` |
| W0801 | redundant match clause | a clause after `(pwild)` |

## Probabilistic inference (E09xx)

| code | meaning | example |
|------|---------|---------|
| E0901 | empty posterior (impossible observations) | `observe (bernoulli 0.0) true` |
| E0902 | runtime failure inside inference | a model dividing by zero |
| E0903 | model file has no expression | a decls-only file passed to `weft infer` |
| E0904 | observe at the sampling root | `observe` under `weft run --allow dist` (D7 default: defect) |

## Appendix: the W5.3 audit (ten message rewrites)

Before/after wording improvements applied during the audit:

1. E0802 before: "not applicable" → after: "`int` is not a function" with the hint naming
   what can be applied.
2. E0801 before: bare "type mismatch" → after: expected/actual fully elaborated plus a hint
   that the expected side comes from context.
3. E0813 before: "match not exhaustive" → after: names the exact missing witness
   (`some(some(false))`) and hints the fix.
4. Unhandled-effect runtime error before: "unhandled op" → after: names both the effect and
   the operation, and the CLI exit code is distinct (3).
5. E0814 before: nothing (new) → names the effect, the call-chain endpoint, and the exact
   `--allow` flag to add.
6. E0605 before: crash (`Bug_unprintable` escaping, truncating names.wft) → after: a clean
   diagnostic stating the name grammar.
7. E0109 before: "invalid int" → after: names the 63-bit native range and decision D2 in
   the hint.
8. E0304 before: silent acceptance across sibling binders → after: a dedicated diagnostic
   naming the variable.
9. div-by-zero before: "type error: division by zero" (miscategorized) → after: a dedicated
   `Arithmetic` runtime error category.
10. E0901 before: NaN posterior from 0/0 → after: "the posterior is empty: every branch is
    impossible under the observations".
