# Effect Taxonomy ET.4 Evidence

Status: reconstructible ET.4 overlay on validated ET.3 commit `950fab6`.

ET.4 promotes D57's Secret contract from its reserved schema to a shipped ring-3
interface. The frozen `DefEffect` identity is
`6d092eccc3c9858a2a95120da5a011964cbb3ad76968e11c1cbb062c119fbb31`.
Its exact operations are once `secret.read : (SecretRef) -> Secret` and once
`secret.expose : (Secret) -> Text`; `SecretRef` is exactly
`SecretRef(name: Text, version: Option Text)`.

## Opacity boundary

- `Secret` has distinct OCaml `VSecret` and native `JQ_SECRET` runtime tags.
- Its marker constructor is absent from public name lookup and direct
  derived-hash lookup, including after store reopen.
- Generic interpreter and native rendering is the fixed marker
  `<secret redacted>`. Nested values, runtime errors, traces, and
  `debug.inspect` use that same marker without reading the payload.
- No Show instance, Code conversion, generic Audit encoder, or serialization
  path accepts Secret. E0818 gives a targeted checker diagnostic for generic
  inspection and Text serialization attempts; ordinary typed Audit rejection
  remains E0801.
- `Prelude.install_secret` requires an embedding to supply an explicit resolver;
  it creates opaque values at `secret.read` and converts them only at
  `secret.expose`. ET.4 defines no ambient provider and adds no CLI grant.
- Kernel names remain flat, so the loader publishes the collision-free aliases
  `secret.read` and `secret.expose` while retaining the historical bare `read`
  binding for Fs. The underlying operation names remain the ratified `read` and
  `expose`, preserving the frozen interface identity.

This is non-derivability, not information-flow or taint tracking. After explicit
exposure the result is ordinary Text; code can copy or leak it. The operational
guidance is therefore to expose late and keep plaintext out of typed Audit data.

## Adversarial evidence

The dedicated `secret` suite pins the complete schema and once modes, qualified
aliases and Fs compatibility, marker non-addressability, explicit provider and
exposure behavior, fixed interpreter inspection, targeted checker failures,
typed Audit rejection, and absence of fixture bytes from runtime/checker errors.
A 300-case property covers arbitrary byte strings directly and nested inside a
tuple.

The native sanitizer lane pins allocation, ownership, explicit internal payload
access, fixed `jq_show`, native `debug.inspect`, and a hostile `code.of-text`
attempt whose exact error contains only the redaction marker. The OCaml/C show
parity corpus also contains a secret fixture while its golden contains only the
marker. The reviewed once-operation native gauntlet grows from 14 to 16 cases
and rejects both Secret operations identically in interpreter and native builds.

## Reproduction

```sh
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp"
export TMPDIR="$PWD/.scratch/tmp"
opam exec -- dune build --root . @all
opam exec -- dune runtest --root . --force
CC=clang runtime/check.sh
opam exec -- dune build --root . @fmt
opam exec -- dune build --root . @doc
sha256sum -c docs/release/effect-taxonomy/ET4-MANIFEST.sha256
```

The ET.4 checkout contains 597 compiled Alcotest/QCheck cases and 32 cram
transcript files. The ET.2 and ET.3 evidence sets remain historical; ET.4
publishes this separate successor overlay.
