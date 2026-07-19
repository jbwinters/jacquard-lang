# Jacquard diagnostic codes

Every diagnostic the toolchain can emit, with an example that triggers it. Domain-qualified
identities are stable: a `(domain, code)` pair is never reused or renumbered. A test enforces that
every code emitted anywhere in `src/`, `bin/`, or the native runtime appears in this catalog.

## Diagnostic structure and rendering

A diagnostic is structured data, not a preformatted message. Every diagnostic has a domain,
severity, plain-language summary, technical cause, and exactly one primary next step. A source
span and stable code may be absent only where the historical boundary has neither; optional
contrast is reserved for one concrete, plausible confusion and records separate `mistaken` and
`intended` descriptions.

The default text renderer presents the author-facing fields in this order:

1. source span, when available, on the severity/code header;
2. plain-language summary;
3. `Cause:` with the technical reason;
4. one `Next step:`;
5. `Contrast:`, only when a specific mistaken/intended distinction applies.

Commands accept `--diagnostic-format=text|json-v1`; `text` remains the default. `json-v1` writes
one compact JSON object per diagnostic to stderr, preserving emission order and exit status. Its
schema name is `jacquard-diagnostic-v1`, with `domain`, nullable `code`, `severity`, nullable
`span`, `summary`, `cause`, and `next_step` fields. A span contains `file`, `start`, and `end`; each
position contains one-based `line` and `column` plus a zero-based byte `offset`. The `contrast`
object is omitted when it does not apply. Machine consumers should key stable identities by the
pair `(domain, code)`, not by code alone, and should tolerate `code: null` for deliberately
code-less runtime failures. Span ends are exclusive, and columns count UTF-8 bytes rather than
Unicode scalar values. Treat `cause` as opaque author-facing text: when one diagnostic explains
another, the child is projected into that text rather than exposed as a second nested JSON schema.
The JSON encoding is always valid UTF-8: well-formed input is preserved byte-for-byte, while each
malformed source, path, or host-message byte in a string field is replaced with U+FFFD.

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

| domain | code | meaning | example |
|--------|------|---------|---------|
| inference | E0901 | empty posterior (impossible observations) | `observe (bernoulli 0.0) true` |
| inference | E0902 | runtime failure inside inference | a model dividing by zero |
| warp | E0902 | runtime failure during exhaustive property execution | an exhaustive property body dividing by zero |
| inference | E0903 | model file has no expression | a decls-only file passed to `jacquard infer` |
| runtime | E0904 | observe at the sampling root | `observe` under `jacquard run --allow dist` (D7 default: defect) |
| warp | E0905 | exhaustive verification budget exceeded | a property over `uniform-int(1, 1000000)` under `jacquard test --exhaustive` |
| runtime | E0906 | a once continuation was resumed more than once | applying the same once resumption twice |
| concurrency | E0907 | a Task or ChannelHandle carrier is private, malformed, foreign to the run, escaped, stale, or outside its exact structured scope | returning/storing a Task or ChannelHandle beyond `async.scope`, constructing its private carrier by hash, reusing it after its creating scope closes or in another run, or using a parent/descendant/foreign handle |
| concurrency | E0908 | a deterministic scheduler, schedule trace, trace I/O, or same-scope policy operation is illegal for its lifecycle, decision order, registration, continuation ownership, configured positive/transport bound, or strict-replay contract | checking out a suspended task, exceeding a task/decision/input bound, observing or scheduling a terminal child twice, reading/writing an unavailable trace path, parsing an unversioned/malformed trace, or replaying a missing, extra, reordered, impossible, queue-drifted, or operation-drifted event |

## Warp (E10xx)

| code | meaning | example |
|------|---------|---------|
| E1001 | expression at top level of a test file | `jacquard test file.jqd` where the file ends with `(app (var main))` |
| E1002 | eval under --dry-run | a program whose row includes `eval` run with `--dry-run` |

## Native compilation (E11xx)

| code | meaning | example |
|------|---------|---------|
| E1101 | program construct is outside the native v1 compilation subset | compiling a call with more than eight arguments |
| E1102 | program requires the interpreter tier | compiling a program that uses `eval` |
| E1103 | native toolchain, grant, or build configuration cannot produce the executable | building with an unsupported `net` grant or unavailable compiler |

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
| E1227 | surface syntax nesting exceeds the structural limit | more than 10,000 nested calls, pipes, parentheses, patterns, or types |
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
| E1302 | unsupported chain version or malformed released AuditEntry | `audit-chain-v3` or a non-v2 entry shape |
| E1303 | broken predecessor linkage | reordered, removed, or duplicated records |
| E1304 | stored digest does not match the predecessor and entry bytes | altering one entry byte without recomputing the record digest |
| E1305 | reconstructed chain head differs from the independently published head | removing the final record or appending from a stale head |
| E1306 | Audit chain I/O failure, size refusal, or concurrent file change | an unreadable/over-limit entry, a log truncated while being read, or its pathname replaced during append |
| E1307 | malformed CLI Audit head | `--head beef` instead of 64 lowercase hexadecimal digits |
| E1308 | noncontiguous AuditEntry sequence | a duplicate, skipped, decreasing, or negative sequence position |

`jacquard governance verify-log LOG --head HASH` verifies offline and fails
closed. It accepts only LF-terminated canonical `audit-chain-v2` records, checks
every predecessor, digest, and exact sequence `0, 1, 2, ...` in order, then compares the reconstruction with the
separately supplied published head. Malformed input returns diagnostics; it does
not raise an exception.

## Governance verifier (E14xx)

| code | meaning | example |
|------|---------|---------|
| E1400 | verifier environment or analysis version is unsupported | rebinding `eval` to a different effect or supplying `governance-verifier-v1` input |
| E1401 | facade effect or operation mode is invalid | a non-`once` facade operation |
| E1402 | facade operation coverage is incomplete or duplicated | a frozen operation with no dry clause |
| E1403 | gate identity, branch coverage, or post-gate ordering is invalid | consuming `Resume` before recording live completion |
| E1404 | audit sequence ownership or token provenance is invalid | two `with-sequence` owners around one published stream |
| E1405 | a normalizer or summarizer is not a closed pure arrow with its exact result shape | an effectful callback hidden inside a normalizer parameter |
| E1406 | a carried identity does not match its canonical subject | a `Call.call-id` copied from different arguments |
| E1407 | action expansion disagrees with the frozen authority envelope | a forwarded operation that introduces undeclared `Net` authority |
| E1408 | gate-owned control authority appears inside the action projection | listing `State` or `Audit` as raw action authority |
| E1409 | governance review data contains a `Secret` or uses generic inspection | embedding a secret in a BoundPolicy subject instead of a `SecretRef` |
| E1410 | an `Ask` proposal does not bind every exact review hash | omitting the assessment identity |
| E1411 | forwarded-call lineage is inconsistent or not anchored to the carried Call | unrelated previous/current IDs that agree only with each other |
| E1412 | governed code can reach `Eval` | handling `Eval` locally and then claiming it is absent |

`Governance_verify.verify` consumes a versioned analysis IR produced by trusted
tooling from resolved, typechecked artifacts. That IR is verifier evidence, not
a user-authored proof or an authority grant. The verifier resolves the real
stored terms, recomputes HASH_V0 identities, expands forwarded action envelopes,
and returns all detected violations with source spans. Resource scopes remain
configured evidence rather than row-type proofs. `Eval` is an absolute
prohibition for governed code, including code that attempts to handle it
locally.

GM.8 provides this library analysis boundary. A later tooling slice may expose
it as `jac governance check`; no such command is implied by these diagnostics.

## Governance run bundle (E15xx)

| code | meaning | example |
|------|---------|---------|
| E1500 | malformed, unsupported, noncanonical, unreadable, or concurrently changed run bundle | a bundle without its final LF or fixed artifact sections |
| E1501 | an artifact is malformed or its carried identity disagrees with its unchanged canonical v0 subject | a Call wrapper carrying the hash of different arguments |
| E1502 | one artifact identity occurs more than once | two Call wrappers carrying the same Call ID |
| E1503 | an Audit entry references an artifact absent from the bundle | `Consented` names a Proposal that was not supplied |
| E1504 | Audit ordering or entry-to-artifact linkage is missing, inconsistent, or ambiguous | consent has no unique earlier matching `Ask` evaluation |
| E1505 | a Proposal's Call, policy, assessment, or authority disagrees with its linked artifacts | a Proposal repeats a different authority envelope |
| E1506 | transformed Call lineage is missing, self-referential, or cyclic | `parent-call-id` names an absent Call |
| E1507 | a bundled artifact is not used by the Audit chain | an unrelated valid Proposal is appended to the bundle |

`jacquard governance verify-run BUNDLE` is additive to `verify-log`. The bundle
contains unchanged `audit-chain-v2` record forms plus full versioned artifacts.
The verifier resolves qualified operation names and hashes through the selected
prelude/store, reconstructs the published head, recomputes the existing v0
Call, BoundPolicy, Assessment, and Proposal identities, checks proposal and
decision links, and verifies explicit parent-Call lineage. It does not infer
that an external action ran, succeeded, or rolled back from an absent
`Completed` entry. Receipt and idempotency reconciliation require a later typed
action journal and are intentionally outside this command.

## Governance action reconciliation (E151x)

| code | meaning | example |
|------|---------|---------|
| E1510 | malformed, unsupported, noncanonical, unreadable, or concurrently changed reconciliation bundle | a nonregular input or missing final LF |
| E1511 | action-journal predecessor, digest, sequence, or published head mismatch | reordering a valid journal record |
| E1512 | Attempted or Receipt semantic identity mismatch | changing the carried attempt ID without changing its subject |
| E1513 | duplicate Attempted identity or second Receipt for one attempt | copying an existing journal entry |
| E1514 | Receipt does not follow an existing Attempted entry | placing a receipt first |
| E1515 | policy/verdict, attempt authorization, Call occurrence, completion, branch, or outcome linkage contradicts the verified run | a Dry Allow, live completion after Block, repeated Call evaluation, or changed receipt outcome |
| E1516 | evidence is structurally valid but operator reconciliation remains | a durable receipt has no matching `Completed` record |

`jacquard governance reconcile BUNDLE` verifies a separate HASH_V0-chained
action journal around one unchanged run bundle. An attempt names the exact
allowing or approving Audit-record digest. A receipt names that attempt, the
exact outcome summary, and an external-receipt digest. Only exact
Call/branch/outcome agreement counts as reconciled. Every live completion is
checked, including when no action-journal entry names it. Unknown attempts,
missing receipts, and missing completions are nonzero reports, never rollback
or safe-retry claims.

## Governance approval queue (E152x)

| code | meaning | example |
|------|---------|---------|
| E1520 | malformed, noncanonical, or unrecognized physical journal framing | an arbitrary non-LF suffix rather than the exact record-envelope prefix |
| E1521 | unsupported queue record, commit, or event version | replacing a v1 record envelope with a different carrier head |
| E1522 | record predecessor, carried identity, or commit identity mismatch | editing a committed Decision without updating its record identity |
| E1523 | malformed GovernanceProposal or noncanonical allowed-approver metadata | submitting duplicate or unsorted principals |
| E1524 | malformed or stale Decision, or invalid authenticated actor binding | an Approved Decision whose approver differs from the host actor |
| E1525 | requested transition conflicts with durable queue state | deciding one proposal differently after a Decision is committed |
| E1526 | unsafe path, bounded-read, lock-adjacent, write, sync, or visibility failure | replacing the locked pathname while a transaction is appended |
| E1527 | queue-backed bridge schema or single-rendezvous workflow mismatch | rebinding a frozen approval identity or performing a second sequential approval Ask |

`Governance_approval_queue` is an explicit OCaml host adapter, not a new
Jacquard effect or ambient file API. It verifies canonical two-line
record/commit transactions under a process-local guard and one nonblocking
whole-file lock. A recognized uncommitted suffix may be reported or durably
truncated to the last commit boundary; committed corruption always fails
closed. The module consumes a proposal ID atomically: under the lock it resolves
the immutable Decision, commits the exact Decision ID, and only then returns
the exact Decision and ID.

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
