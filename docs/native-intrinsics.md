# Native intrinsics inventory (task 67)

Every builtin marker the prelude registers (prelude/04-builtins.jqd plus the
`optional` registrations in `Prelude.wire_builtins`), against its native
status. A program that reaches an unimplemented builtin is refused at build
time with the builtin's name (E1101). Implementations live in
runtime/jq_intrinsics.c and must reproduce the interpreter's behavior and
error texts exactly; the differential harness is the check.

| builtin | arity | native | notes |
| --- | --- | --- | --- |
| add, sub, mul | 2 | yes | 63-bit wrap parity |
| div, mod | 2 | yes | zero-divisor errors pinned |
| eq, lt | 2 | yes | booleans via rt |
| int-compare | 2 | yes | ordering cons via rt |
| add-real, sub-real, mul-real, div-real | 2 | yes | IEEE, inf/nan pass through |
| lt-real | 2 | yes | |
| text.length | 1 | yes | jq_utf8 (task 66) |
| text.concat | 2 | yes | |
| text-compare | 2 | yes | bytewise + length tiebreak |
| text.slice | 3 | not yet | needs boundary walk; next slice batch |
| text.trim, text.split | 1/2 | yes | task 70 (word-count reaches them); ASCII trim, empty pieces kept |
| text.join | 2 | not yet | |
| text.contains? | 2 | not yet | |
| text.empty? | 1 | yes | task 70 |
| text.from-int | 1 | yes | task 70; plain text result |
| code.eq (marker) | 2 | task 73 | metadata-erased equality |
| text.to-int, text.to-real, text.from-real | 1 | not yet | option results |
| code.form, code.un-form, code.of-int, code.to-int | - | task 73 | form representation |
| code.to-text, code.diff | - | task 73 | needs the ported printer |
| code.of-text | - | refused for good | it is the reader |
| eval-code | - | refused for good | interpreter tier only |
| debug.inspect | 1 | not yet | |
| pmf, support, dist.sample-lw | - | task 72 | dist drivers |
| add-real family duplicates none | | | |
