# Jacquard diagnostic codes

Every diagnostic the toolchain can emit, with an example that triggers it. Codes are
stable: never reused, never renumbered. A test enforces that every code emitted anywhere
in `src/` and `bin/` appears in this catalog.

## Process safety (E00xx)

| code | meaning | example |
|------|---------|---------|
| E0003 | last-resort host-stack guard for an unbounded internal path | input that reaches an unguarded recursive path before a structural depth diagnostic |

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
| E0115 | bootstrap form nesting exceeds the structural limit | more than 10,000 nested `.jqd` forms |

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
| E0213 | invalid explicit operation mode | `(op fetch multi () (tref text))` (legacy `multi` is encoded by absence) |
| E0214 | kernel form nesting exceeds the structural limit | more than 10,000 nested expression, pattern, type, or quote-payload forms |

## Name resolution (E03xx)

| code | meaning | example |
|------|---------|---------|
| E0301 | unknown name (with near-miss suggestions) | `(var ad)` when `add` exists |
| E0302 | name kind mismatch | `(ann (lit 1) (tref add))` — a term used as a type |
| E0303 | duplicate binding name in a defterm group or surface definition run | two bindings named `f` |
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
| E0601 | unknown hash | `jacquard store name s x 000...0` |
| E0602 | unknown name | renaming a name that is not bound |
| E0603 | corrupt store file | hand-edited `names.jqd` or object file |
| E0604 | unnameable target | naming a defterm group's whole hash |
| E0605 | invalid name | `jacquard store rename s x "Bad Name"` |
| E0606 | diff source or store does not exist | `jacquard diff a /nowhere` |
| E0607 | name bound to several kinds; needs --kind | renaming `abort` when it is both an effect and an op |
| E0608 | unknown --kind value | `jacquard store rename --kind bogus` |
| E0609 | invalid, mismatched, or unreadable diff operands | diffing a file against a store |
| E0610 | diff source contains a top-level expression | diffing a runnable script instead of declarations |

## Prelude and grants (E07xx)

| code | meaning | example |
|------|---------|---------|
| E0701 | prelude directory missing | `--prelude /nowhere` |
| E0702 | prelude name missing or wrong kind | truncated prelude |
| E0703 | effect not grantable | `--allow filesystem` |
| E0704 | store add expects declarations only | an expression in `jacquard store add` |

## Type and effect checker (E08xx, W08xx)

| code | meaning | example |
|------|---------|---------|
| E0801 | type mismatch (expected vs actual, elaborated) | `(app (var add) (lit 1) (lit "x"))` |
| E0802 | application of a non-function | `(app (lit 3) (lit 1))` |
| E0803 | arity mismatch (call, op clause, resumption) | one-parameter lambda applied to two |
| E0804 | annotation mismatch | `(ann (lit 1) (tref text))` |
| E0805 | reference kind mismatch or unknown hash | `(groupref 5)` outside a group |
| E0806 | constructor pattern arity | `(pcon some)` with no argument |
| E0807 | bare surface term reference where a compatible thunk is expected | `condition = True; bool.and-then(True, condition)` instead of wrapping `condition` in `fn () -> condition` |
| E0810 | type constructor arity (kind) error | `(tapp (tref option) a b)` |
| E0811 | unbound type or row variable | `(tvar zz)` in a declaration |
| E0812 | unbound variable in an effect op signature | `(op o () (tvar zz))` |
| E0813 | non-exhaustive match (with witness) | bool match missing `false` |
| E0814 | ungranted effect in the program manifest | running a printing program without `--allow console` |
| E0815 | effectful top-level definition body | `(defterm ((binding x () (app (var print) ...))))` |
| E0816 | a once resumption may be consumed twice on one possible path | two sequential calls to the same once-clause `resume` binder |
| E0817 | a once resumption escapes its handler clause | returning, storing, capturing, or passing `resume` to a non-`Resume` parameter |
| E0818 | polymorphic reuse of a non-value local binding (value restriction) | bind an application result, then call it at two unrelated types |
| E0819 | opaque Secret used by generic inspection or serialization | passing a `Secret` to `debug.inspect` or a Text encoder instead of explicitly calling `secret.expose` |
| W0801 | redundant match clause | a clause after `(pwild)` |

E0817 has one bounded transformer exception: a direct clause lambda may capture
`resume` when its `handle` expression is immediately applied once to syntactic
value arguments. Inside that lambda, a call of `resume` must be the direct
function child of one nested application with syntactic-value arguments so its
answer is immediately eliminated; binding or duplicating an answer that could carry a later Once token
emits E0817. Binding, returning, storing, passing, or aliasing the handler result
also emits E0817; consuming the captured resumption twice emits E0816.

## Runtime and probabilistic inference (E09xx)

| code | meaning | example |
|------|---------|---------|
| E0901 | empty posterior (impossible observations) | `observe (bernoulli 0.0) true` |
| E0902 | runtime failure inside inference | a model dividing by zero |
| E0903 | model file has no expression | a decls-only file passed to `jacquard infer` |
| E0904 | observe at the sampling root | `observe` under `jacquard run --allow dist` (D7 default: defect) |
| E0905 | exhaustive verification budget exceeded | a property over `uniform-int(1, 1000000)` under `jacquard test --exhaustive` |
| E0906 | a once continuation was resumed more than once | applying the same once resumption twice |
| E0907 | a Task carrier is private, malformed, foreign to the run, or outside its structured scope | constructing `TaskOpaque` by hash or reusing a Task in another run/scope |

## Warp (E10xx)

| code | meaning | example |
|------|---------|---------|
| E1001 | expression at top level of a test file | `jacquard test file.jqd` where the file ends with `(app (var main))` |
| E1002 | eval under --dry-run | a program whose row includes `eval` run with `--dry-run` |

## Surface syntax (E12xx)

| code | meaning | example |
|------|---------|---------|
| E1200 | retired surface-parser scaffold diagnostic; reserved and no longer emitted | an older build rejecting every nonempty `.jac` file |
| E1201 | canonical surface printer is not implemented at this scaffold boundary | calling the SS.1 printer placeholder |
| E1202 | recovered surface tree still contains holes | checking malformed `.jac` after parser recovery |
| E1203 | kernel subtree has no self-contained surface fragment | rendering an ambiguous raw `group` in a semantic diff |
| E1210 | unexpected surface character | `@` outside a string |
| E1211 | malformed surface identifier | `bad--name` without a kind escape |
| E1212 | malformed or overflowing numeric literal | `1..2` |
| E1213 | unterminated surface string | `"missing close` |
| E1214 | invalid surface string escape | `"\\q"` |
| E1215 | malformed kind-tagged escaped name | `` `wat:name` `` |
| E1216 | malformed kind-tagged hash reference | `#abc:term` |
| E1217 | malformed internal group reference | `#group[x]` |
| E1218 | invalid raw UTF-8 scalar in a surface string | a raw `0xff` byte between quotes |
| E1220 | unexpected token in the recovering surface parser | stray `|` at top level |
| E1221 | unclosed braced construct during surface recovery, with opening and failure spans | a `quote`, `match`, `handle`, or block truncated before `}` or closed with `]`/`)` |
| E1222 | reserved pre-SS.9 binding-pattern parser gate; refutable binders now use E0205/E0206 during lowering | `fn (Some) -> 1` |
| E1223 | missing block-item separator | `{ 1 2 }` instead of `{ 1; 2 }` |
| E1224 | a term signature is not followed by the same definition | `x : T; x = value` |
| E1225 | malformed type/effect declaration structure | `type Option a = Some(a)` |
| E1226 | malformed handler boundary, clause, or raw inversion escape | `handle match x { ... } { ... }` without the D35 body wrapper |
| E1227 | surface syntax nesting exceeds the structural limit | more than 10,000 nested parentheses, patterns, or types |
| E1230 | surface node is outside the SS.7 local-lowering slice | lowering a list before SS.12 |
| E1231 | empty expression block | `{}` |
| E1232 | local `let` is the final block item | `{ let x = 1 }` |
| E1233 | malformed local recursive/function binding | `let rec (f, g)(x) = x` |
| E1234 | generated lowering node lacks a real source span | lowering a hand-built spanless block AST |
| E1235 | a signature or definition was lowered without its required file context | calling `lower_top` on a signature |
| E1236 | missing, duplicated, or conflicting surface operation mode; an omitted mode includes migration guidance | `effect E where { op : () -> T }` |

### Surface warnings (W12xx)

| code | meaning | example |
|------|---------|---------|
| W1201 | lowercase binding pattern shadows an in-scope constructor differing only in case | `match Up { | up -> ... }` |
| W1202 | positional constructor pattern has more than four fields | `Snapshot(_, _, _, _, _)` |
| W1203 | match scrutinee spans more than four source lines | manually bind the expression with `let`, then match on its name |

## Explicit bootstrap export (E13xx)

| code | meaning | example |
|------|---------|---------|
| E1301 | export destination collision | `jac export a.jac -o existing.jqd` |
| E1302 | export input is missing, unreadable, stdin, or non-regular/non-seekable | `printf '1' \| jac export - -o out.jqd` |
| E1303 | same-directory atomic publication failed | exporting into a missing or unwritable directory |

The recovering `.jac` lexer emits an in-order invalid-token marker and continues;
the strict lexer remains fail-fast. Malformed strings resynchronize at a closing
quote or newline, so an unterminated line does not discard valid later items. The
parser synchronizes at construct boundaries including `}`, wrong `]`/`)` closers, `|`, `;`, and
newline so a malformed expression does
not hide later syntax errors. Unclosed `quote`, `match`, `if`, `handle`, and block
diagnostics use the failure token as the primary span and name the opening span in
the hint. Each damage site leaves an explicit surface hole or synthetic delimiter
marker with a stable `surface-hole` ID and `surface-form = recovery-hole` or
`recovery-delimiter` provenance. `Surface_parse.strict` rejects both error diagnostics
and any remaining hole before lowering. Semantic boundaries also recursively reject
marked trees before strict checking, execution, storage, or canonical hashing,
including markers nested in patterns, types, handlers, and quote payloads.
`Surface_check.analyze` is the separate editor/recovery API: it checks marked hole
sentinels as fresh types with no effects in a fresh isolated checker context and
returns only diagnostics and inferred signatures. Successfully checked term islands
are available to later islands through analysis-local names and schemes without
installing declarations in the store. Type and effect declarations are checked in
isolation; references to them from later islands require strict installation first.

## Audit chain (E13xx)

| code | meaning | example |
|------|---------|---------|
| E1301 | malformed or noncanonical Audit chain carrier | a blank line, alternate whitespace, or missing final LF |
| E1302 | unsupported chain version or malformed released AuditEntry | `audit-chain-v2` or a non-v1 entry shape |
| E1303 | broken predecessor linkage | reordered, removed, or duplicated records |
| E1304 | stored digest does not match the predecessor and entry bytes | altering one entry byte without recomputing the record digest |
| E1305 | reconstructed chain head differs from the independently published head | removing the final record or appending from a stale head |
| E1306 | Audit chain I/O failure, size refusal, or concurrent file change | an unreadable/over-limit entry, a log truncated while being read, or its pathname replaced during append |
| E1307 | malformed CLI Audit head | `--head beef` instead of 64 lowercase hexadecimal digits |

`jacquard governance verify-log LOG --head HASH` verifies offline and fails
closed. It accepts only LF-terminated canonical `audit-chain-v1` records, checks
every predecessor and digest in order, then compares the reconstruction with the
separately supplied published head. Malformed input returns diagnostics; it does
not raise an exception.

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
6. E0605 before: crash (`Bug_unprintable` escaping, truncating names.jqd) → after: a clean
   diagnostic stating the name grammar.
7. E0109 before: "invalid int" → after: names the 63-bit native range and decision D2 in
   the hint.
8. E0304 before: silent acceptance across sibling binders → after: a dedicated diagnostic
   naming the variable.
9. div-by-zero before: "type error: division by zero" (miscategorized) → after: a dedicated
   `Arithmetic` runtime error category.
10. E0901 before: NaN posterior from 0/0 → after: "the posterior is empty: every branch is
    impossible under the observations".
