# Effect Taxonomy ET.2 Evidence

Status: reconstructible ET.2 overlay on validated ET.0/ET.1 commit `8bb10e6`.

ET.2 promotes Audit from its reserved first-release schema to the shipped ring-3
prelude interface. The frozen `DefEffect` identity is
`2c148fbc2e26bdc6f01279a8bf176f54d5798536e1f96805aa4f7c7a57e67632`;
its only operation is once `audit.record : (AuditEntry) -> ()`.

The released v1 data boundary consists of `Hash`, `Risk`, `Verdict`,
`Assessment`, `OutcomeSummary`, `Decision`, and `AuditEntry`, whose entry
constructors are `Evaluated`, `Consented`, and `Completed`. Their exact
declaration and member identities are pinned in
`corpus/golden/prelude-hashes.golden`.

`Hash` is an opaque validated host value, not a text-field record. Its marker
constructor is absent from both the public name and derived-hash indexes, and
the installed OCaml API exposes `Hash.t` abstractly. `hash.parse` accepts only
the unique 64-lowercase-hex HASH_V0 spelling, `hash.to-text` returns that
spelling, and `code.of-hash` emits the digest as a canonical hash scalar.

## Handler contract

- `audit.in-memory` returns entries in occurrence order and performs no world
  effect.
- `audit.entry-code` constructs versioned Code/form data from typed fields.
- `audit.line-log` sends exactly one compact reparsable form plus LF to an
  injected append-line callback. It never calls `debug.inspect` or serializes an
  arbitrary runtime value.
- The append callback returns `Result Text ()`; `Err` promises no bytes were
  appended. The handler does not resume after `Err`, making pre-action audit
  failure fail-closed.
- A failed `Completed` write is surfaced but cannot roll back the already
  completed action. No implicit retry hides an ambiguous append result.

## Reproduction

```sh
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp"
export TMPDIR="$PWD/.scratch/tmp"
opam exec -- dune exec test/gen_prelude_goldens.exe
opam exec -- dune build @all
opam exec -- dune runtest --force
opam exec -- dune fmt
opam exec -- dune build @doc
CC=clang scripts/native-diff.sh
CC=clang scripts/native-leak-check.sh
sha256sum -c docs/release/effect-taxonomy/MANIFEST.sha256
```

The dedicated `audit` suite pins constructor/effect identity, opaque Hash
acceptance and rejection by name, direct hash, and unchecked evaluation,
ordinary direct constructor/member compatibility, in-memory order, all three
deterministic encodings,
append order across handler invocations, injected pre-write failure,
post-action completion failure, and a 40-case determinism/reparse property.
Every property case covers every entry variant, nested Code, control and UTF-8
text, and finite, infinite, and NaN confidence values.

The direct g36 native gauntlet pins canonical Hash acceptance/rejection,
first-class Hash rendering directly and nested in `Ok`, ordinary direct
constructor/member compatibility, `code.render`, and Audit line-log output
byte-for-byte. The native runtime unit lane separately pins raw and
constructor-nested Hash rendering plus leak-free ownership. The reproduced gates
observed 587/587 Alcotest/QCheck cases passing, 69 native programs identical
with 8 manifested refusals and 0 failures, and all 53 ASAN/leak witnesses clean
(including g36).
