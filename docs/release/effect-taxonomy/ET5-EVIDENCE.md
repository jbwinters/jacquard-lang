# Effect Taxonomy ET.5 Evidence

Status: reconstructible ET.5 overlay on validated ET.4 commit `9b402ae`.

ET.5 adds canonical handler boundaries around the unchanged ET.4 Secret
interface and opaque runtime representation. It does not change the frozen
`SecretRef`, `Secret`, `secret.read`, or `secret.expose` identities.

## Handler boundaries

- `Prelude.install_secret_fixed` accepts an ordered fixture set and resolves an
  exact `(name, version)` deterministically. Missing references and missing
  versions are distinct sanitized failures. The handler performs no IO or
  logging.
- `--allow secret` explicitly installs `Prelude.install_secret_environment`.
  Its collision-free environment keys encode the safe reference bytes as
  lowercase hex. Environment values become `VSecret` immediately and never
  enter diagnostics.
- `Prelude.install_secret_vault` accepts an injected callback. No provider,
  transport, authentication convention, or retry policy is selected. Its
  closed `secret_lookup_error` variants contain no backend message or value, so
  missing-reference, missing-version, and backend-failure diagnostics cannot
  echo confidential material.
- Dry-run bypasses live grant installation. Secret is deliberately absent from
  the dry grant set, so a remaining Secret row is rejected before evaluation
  even when `--allow secret` is present.

These handlers preserve ET.4 non-derivability and fixed redaction. This remains
an opacity boundary, not taint tracking: after `secret.expose`, ordinary Text
may be copied or leaked.

## Adversarial evidence

The dedicated Secret suite pins repeated fixed lookup, exact version
selection, sanitized missing cases, injected environment lookup, scripted
vault replay, safe reference-only call recording, and a backend fault. It also
retains ET.4's schema, store opacity, E0818/E0801, generic redaction, and
300-case arbitrary-byte property.

`test/cli/secret.t` proves an ungranted program refuses with E0814, an explicit
Secret grant installs the environment adapter, absent names and versions fail
without values, versioned exposure retains the grant, and dry-run installs no
live resolver. Both successful live transcripts scan stdout and stderr for a
non-sensitive fixture assembled by the shell and require it to be absent.

The ET.4 public-API, native sanitizer, show parity, hostile conversion, and
once-operation lanes remain unchanged and continue to prove that alternate
generic rendering paths cannot reveal an opaque value.

## Reproduction

```sh
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp"
export TMPDIR="$PWD/.scratch/tmp"
opam exec -- dune runtest --root . test/cli/secret.t --force
cd test && ../_build/default/test/test_jacquard.exe test '^secret$' --color=never
cd ..
opam exec -- dune build --root . @all
opam exec -- dune build --root . @fmt
opam exec -- dune build --root . @doc
sha256sum -c docs/release/effect-taxonomy/ET5-MANIFEST.sha256
```

The ET.5 checkout contains 599 compiled Alcotest/QCheck cases and 33 cram
transcript files. Predecessor evidence and manifests remain historical.
