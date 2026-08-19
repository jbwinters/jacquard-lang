# Host protocol v0 vectors

`vectors.json` is the normative HB.1 schema and state-machine corpus for
`jacquard-host-v0`. Read it with [`../host-protocol-v0.md`](../host-protocol-v0.md).

The file is data, not a transcript of a released carrier. Its 64-digit
identities are deliberately synthetic and well formed; they do not claim that
a Jacquard store contains those objects. HB.2 adds executable Core artifacts,
and HB.3 packages those artifacts for independent adapters.

## Format

- `hard_limits` repeats the exact maxima in the specification.
- `templates` contains complete semantic frames. Each template records its
  direction and message. An exact object `{"$ref":"hard_limits"}` expands to
  the top-level `hard_limits` object before use.
- `positive` contains valid success, refusal, ambiguous-timeout, and graceful
  shutdown template sequences with the expected terminal result. A conforming
  state machine accepts every sequence.
- `terminal_mappings` exhaustively maps the four valid host-failure pairs and
  all nine cancellation `(reason, completion)` pairs to a diagnostic and Core
  terminal category.
- `hostile` starts from a named positive sequence and applies exactly one
  mutation. JSON-pointer paths address the expanded message at the stated
  zero-based frame index. `append` adds one named template after the base
  sequence. `raw_wire` supplies complete or deliberately incomplete bytes as
  lowercase hexadecimal and does not use a semantic template.

Each hostile expectation states the primary E16xx code, the number of effect
requests Core may have emitted before refusing the case, and the maximum
number of structured terminal frames. `forbid_outside_action` means the case
must fail before adapter execution, even if its malformed envelope contains
plausible action text.

Phase also fixes the rejecting side and terminal shape. `framing`,
`host_select`, and `invoke` are rejected by Core with one `fatal` in the
controlled harness. `evaluation` and `effect_response` are rejected by Core
with one error `outcome`. `terminal` is rejected locally by the host state
machine before it writes after the already-recorded outcome. Raw truncated
input assumes stdout remains writable; bidirectional loss may prevent the
fatal outside the controlled vector harness.

JSON object order and insignificant whitespace are not conformance inputs.
Duplicate-key and invalid-UTF-8 cases use `raw_wire` because an ordinary parsed
JSON object cannot retain those defects.

## Updating

Changing a template field, state sequence, mutation, limit, expected code, or
forbidden-action boundary changes the frozen protocol. It requires a reviewed
protocol-version decision, not a mechanical golden refresh. Additive cases
that expose an already-specified edge may remain v0 when they do not make a
previously rejected message valid.

The OCaml test suite checks the vector document's schema, identities, limits,
template directions, positive state sequences, authority evidence echoes,
the complete terminal matrix, resolvable mutation pointers, raw hex, unique
names, and complete E1600-E1614 case coverage. HB.2 must make the same cases
executable rather than weakening these checks.
