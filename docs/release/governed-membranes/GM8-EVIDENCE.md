# Governed Membranes GM.8 Evidence

Status: reconstructible GM.8 overlay on exact integrated commit `491e530`.

GM.8 adds the static cross-artifact verifier required by
`docs/effect-membranes.md` §12.2 and §13. Row typing already exposes the broad
effect boundary, but it cannot by itself prove that a membrane's call,
proposal, policy, action, gates, audit sequence, and forwarding lineage all
refer to the same operation. The verifier closes those relationships before a
governed computation runs.

This is a library analysis boundary. It does not add syntax, kernel forms,
runtime effects, handlers, drivers, or a command-line command.

## Versioned analysis boundary

`Governance_verify.verify` accepts `governance-verifier-v0`, a typed analysis IR
derived by trusted tooling from resolved and typechecked Jacquard artifacts.
The IR records source metadata and relationships that are not expressible in a
single inferred effect row. It is verifier evidence, not a serialized policy
format, a user-authored proof, or an authority grant.

The verifier resolves actual referenced terms from `Store`, confirms canonical
effects through the frozen effect registry, and pins the v0 governance terms
and result types by hash rather than trusting mutable name bindings. Missing or
rebound vocabulary, unknown operations, unresolved terms, and unsupported
evidence versions fail closed. Verification does not evaluate terms or mutate
the store. A later tooling slice may extract this evidence and expose `jac
governance check`; GM.8 does not claim that interface.

## Checked relationships

For every canonical `once` facade operation, the verifier checks:

- exact operation coverage and both live and dry branch sets;
- canonical live/dry gate identities and branch-specific action, completion,
  and local `Resume` ordering;
- one outer audit-sequence owner and exact binder-token provenance through all
  nested layers;
- closed, pure inferred schemes for the actual stored call normalizer and
  outcome summarizer, including every nested arrow and their exact result
  shapes, plus a canonical `governance.make-call` dependency;
- recomputed HASH_V0 identities for Call, BoundPolicy, assessment, and Proposal;
- equality between the frozen, Call, Proposal, and transitively expanded action
  authority envelopes;
- exclusion of gate-owned State, Judge, GovernanceApprovalV1, Audit, and local
  continuation control from the action projection;
- absence of Secret values across serialized data and every canonical review
  subject, plus independent rejection of generic inspection in both the
  normalizer and summarizer, while allowing safe `SecretRef` evidence;
- exact Ask bindings for call, policy, assessment, and authority hashes;
- stable unchanged forwarding and explicit parent/new identity for transformed
  calls, with every current lineage ID anchored to the operation's carried
  Call; and
- the absolute absence of reachable `Eval`, even if code attempts to handle it
  locally.

Resource scope and configuration entries are compared as configured evidence.
They are deliberately not inferred from effect rows and do not claim a
resource-scope type proof.

## Stable diagnostics and adversarial evidence

Failures use E1400--E1412, documented in `docs/errors.md`. The focused suite
constructs a valid three-operation Workspace contract using the released
Workspace facade, its real stored normalizers and summarizers, exact gate
identities, and the Fs/Fs/Net+Secret frozen authority envelopes. It also proves
transitive forwarding and structured resource evidence.

The versioned corpus names 44 independent adversarial mutations. The focused
suite applies them and asserts both the stable E-code and the originating
source span. The cases cover version/environment refusal,
facade mode, operation and branch coverage, gate and flow ordering, sequence
ownership, term purity, canonical call construction, all identity claims,
authority expansion, control-effect exclusion, Secret serialization, generic
inspection, Ask completeness, call lineage, and reachable `Eval`. The
diagnostic-catalog test pins the complete public code set. A cram transcript
runs this analysis lane from its built artifact and records success without
claiming the later public CLI.

The adversarial catalog includes canonical name rebinding, duplicate and
missing clause coverage, an effect hidden in a nested function parameter,
malformed nested resource evidence, Secret-bearing BoundPolicy and assessment
subjects, simultaneous inspection in both review functions, and internally
consistent lineage IDs that are unrelated to the carried Call. The reference
walker records every visited term globally, so shared dependency graphs remain
linear in the number of reachable stored terms.

## Explicit exclusions

GM.8 does not implement the Workspace live or dry membrane, a simulator or raw
driver, the governance CLI/explanation surfaces, artifact extraction, or a
resource-scope proof. It also does not treat the analysis IR as sufficient
evidence on its own: trusted tooling must derive it from checked artifacts, and
the verifier independently resolves every term and canonical identity it can
against the supplied store.

## Reproduction

```sh
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp"
export TMPDIR="$PWD/.scratch/tmp"
opam exec -- dune build --root "$PWD" @all
cd test && ../_build/default/test/test_jacquard.exe test \
  'governance-verify|workspace|governance-core|governance-gate' \
  --compact --color=never
cd ..
opam exec -- dune runtest --root "$PWD" --force
opam exec -- dune build --root "$PWD" @fmt
opam exec -- dune build --root "$PWD" @doc
sha256sum -c docs/release/governed-membranes/GM8-MANIFEST.sha256
```

The GM.8 overlay contains the public verifier contract and implementation, its
focused Workspace and adversarial suite, the stable diagnostic catalog, and
this evidence. The integrated successor inventory is 728 compiled
Alcotest/QCheck cases, 41 cram transcript files, and 27 documentation examples
across 8 documents. The exact manifest excludes itself to avoid a self-hash.
