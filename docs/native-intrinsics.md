# Native intrinsics inventory (task 67)

Every builtin marker the prelude registers (prelude/04-builtins.jqd plus the
`optional` registrations in `Prelude.wire_builtins`), against its native
status. A program that reaches an unimplemented builtin is refused at build
time with the builtin's name (E1101). Implementations live in
runtime/jq_intrinsics.c and must reproduce the interpreter's behavior and
error texts exactly within native v1's global eight-argument application
ceiling; the differential harness is the check. The five renamed real
operations retain their historical marker IDs so their semantic hashes remain
stable while only the public name index changes.

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
| text.slice | 3 | not yet | needs boundary walk; next slice batch |
| text.trim, text.split | 1/2 | yes | task 70 (word-count reaches them); ASCII trim, empty pieces kept |
| text.contains? | 2 | not yet | |
| text.empty? | 1 | yes | task 70 |
| text.from-int | 1 | yes | task 70; plain text result |
| code.eq? | 2 | yes | task 73; metadata-erased equality, OCaml real compare (nan = nan) |
| text.to-int, text.to-real, text.from-real | 1 | not yet | option results |
| code.form, code.un-form, code.of-int, code.to-int | 2/1/1/1 | yes | task 73; head grammar validated, un-form splits all-form args only; runtime-built forms cap at 32767 args (uint16 representation, clean abort) |
| code.to-text, code.diff | 1/2 | yes | task 73; diff renders smallest disagreeing subtrees over the ported inline printer |
| code.of-text | - | refused for good | it is the reader |
| eval-code | - | refused for good | interpreter tier only |
| debug.inspect | 1 | not yet | |
| pmf, support | 2/1 | yes | task 71 (the enum handler reaches them); name-recognized dist cons, show-based pmf equality, interpreter's exact error texts |
| dist.sample-lw | 3 | yes | task 72; exact seeded stream (split per run, one draw per sample), merge/normalize/sort on the rendering key, E0901 on an empty posterior |
| obsolete hyphenated real family public names | | no | removed in SS.22; historical IDs are internal and create no duplicate objects |
