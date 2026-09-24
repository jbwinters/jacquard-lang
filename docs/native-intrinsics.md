# Native intrinsics inventory (task 67)

Every builtin marker the prelude registers (prelude/04-builtins.jqd plus the
`optional` registrations in `Prelude.wire_builtins`), against its native
status. A program that reaches an unimplemented builtin is refused at build
time with the builtin's name (E1101). Implementations live in
runtime/jq_intrinsics.c and must reproduce the interpreter's behavior and
error texts exactly within native v1's global eight-argument application
ceiling; the differential harness is the check. That ceiling belongs to the
fixed calling convention: a variadic intrinsic applied directly, such as the
`text.join` behind marked interpolation, receives an array and a count and is
not capped by eight, while applying the same builtin as a value still is. The
count is a 16-bit width in the runtime signature, so a direct variadic
application of more than 65535 arguments is refused at build time (E1101)
rather than truncated. The five renamed real operations retain their
historical marker IDs so their semantic hashes remain stable while only the
public name index changes.

| builtin | arity | native | notes |
| --- | --- | --- | --- |
| add, sub, mul | 2 | yes | 63-bit wrap parity |
| div, mod | 2 | yes | zero-divisor errors pinned |
| eq, lt | 2 | yes | booleans via rt |
| int-compare | 2 | yes | ordering cons via rt |
| real.add, real.sub, real.mul, real.div | 2 | yes | stable IDs `add-real`, `sub-real`, `mul-real`, `div-real`; IEEE, inf/nan pass through |
| real.gt?, real.gte?, real.lt?, real.lte? | 2 | yes | `real.lt?` retains stable ID `lt-real`; ordered comparisons; NaN makes each false |
| text.length | 1 | yes | jq_utf8 (task 66) |
| text.concat | 2 | yes | |
| text.join marker (`text.join-list`) | 2 | yes | deprecated pre-SS.22 `(List Text, Text)` compatibility object; historical hash and marker retained |
| text.join-variadic-v1 marker (`text.join`) | 0-8 | yes | distinct homogeneous variadic Text concatenation object; native v1 application cap |
| text-compare | 2 | yes | bytewise + length tiebreak |
| text.slice | 3 | yes | APP.5; codepoint-indexed `[a, b)` clamped to the text, walked with jq_utf8_width |
| text.trim, text.split | 1/2 | yes | task 70 (word-count reaches them); ASCII trim, empty pieces kept |
| text.contains? | 2 | yes | APP.5; byte substring scan, empty needle always contained |
| text.empty? | 1 | yes | task 70 |
| text.from-int | 1 | yes | task 70; plain text result |
| text.from-real-fixed | 2 | yes | APP.6; C `%.*f` on the exact binary value, sign dropped on a zero result, non-finite spellings, precision 0..20 else the interpreter's arithmetic error |
| text.ascii-digit?, text.ascii-letter?, text.ascii-space? | 1 | yes | APP.6; exactly one ASCII byte of the class |
| text.ascii-digit-value, text.codepoint | 1 | yes | APP.6; option results; codepoint uses the D9 width table so malformed bytes yield none |
| real.from-int | 1 | yes | APP.6; C `(double)` cast, nearest even like `float_of_int` |
| code.eq? | 2 | yes | task 73; metadata-erased equality, OCaml real compare (nan = nan) |
| text.to-int, text.to-real, text.from-real | 1 | yes | APP.5; the reader's numeric atom grammar ported (`Reader.classify_literal`: optional sign, `digits[.digits][e[+-]digits]`, Scheme `+inf.0`/`-inf.0`/`+nan.0`), 63-bit overflow → `none`, ints accepted by `to-real`; `from-real` shares `jq_show`'s real spelling |
| code.form, code.un-form, code.of-int, code.of-real, code.to-int | 2/1/1/1/1 | yes | task 73 plus ET.2 real-form support; head grammar validated, un-form splits all-form args only; runtime-built forms cap at 32767 args (uint16 representation, clean abort) |
| code.of-text, code.of-hash, code.to-text, code.render, code.diff | 1/1/1/1/2 | yes | ET.2 adds typed scalar construction and the deterministic compact renderer; diff renders smallest disagreeing subtrees over the same ported inline printer |
| code.hash | 1 | yes | ET.6 applies HASH_V0 to the same metadata-erased canonical compact Code bytes as `code.render`; interpreter/native parity is pinned by g37 |
| hash.parse, hash.to-text | 1/1 | yes | ET.2 opaque HASH_V0 boundary; parsing accepts only 64 lowercase hexadecimal digits and native values use the existing 32-byte `JQ_HASH` carrier |
| governance.effect-order-key marker (`governance.effect-order-key-v0`) | 1 | yes | GM.9 pure frozen-taxonomy ordering; all 28 catalog positions of taxonomy v3 (26 v1 rows, GovernanceApprovalV1, ConsoleInput), including reserved gaps, match `Effect_registry.catalog`; unknown hashes sort deterministically afterwards; g38 reaches authority validation on both engines |
| eval-code | - | refused for good | interpreter tier only |
| debug.inspect | 1 | yes | `jq_show` parity; `JQ_SECRET` always yields the fixed `<secret redacted>` marker |
| pmf, support | 2/1 | yes | task 71 (the enum handler reaches them); name-recognized dist cons, show-based pmf equality, interpreter's exact error texts |
| dist.sample-lw | 3 | yes | task 72; exact seeded stream (split per run, one draw per sample), merge/normalize/sort on the rendering key, E0901 on an empty posterior |
| dist.sample-lw-weights-v1 | 3 | yes | INF.1; the same seeded runs as dist.sample-lw, returned oldest first and unnormalized, without the impossible runs (an exact zero observation factor, or a draw from a zero-mass categorical); `dist.sample-lw-v1` classifies them in the prelude |
| obsolete hyphenated real family public names | | no | removed in SS.22; historical IDs are internal and create no duplicate objects |

Every Text and numeric builtin the interpreter ships is in the table above with
native status `yes`: the text/numeric remainder is empty as of APP.5 (repairs of
shipped operations) and APP.6 (the additive presentation and classification
names). End-of-input-aware terminal input is a grant (`next-line`, APP.7), not a
builtin marker, and is listed with the native grants in `docs/native-plan.md`.
Not in this table: the `async.scope-v0`, `governance.*-v0`, and
`posterior.*-v1` markers, which are documented with their own subsystems.
