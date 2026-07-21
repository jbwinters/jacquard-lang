# Governed Membranes GM.17B static why-effect evidence

Status: release-hardening implementation overlay on exact integrated base
`4b0670fe8a0341708bdf51696e8dd29db6527674`.

## Context

GM.16 verifies that source uses the released Workspace membrane, but its frozen
report intentionally says nothing about which source call sites can reach a
particular raw authority. A reviewer asking “why does this source need Fs?”
would otherwise have to inspect source references, forwarding layers, facade
operations, raw drivers, and effect hashes by hand. An elaborated effect row is
not enough: it does not distinguish evaluating a function value from invoking
it and is not execution provenance.

GM.17B adds a bounded, conservative source-attribution view over the exact
GM.16 verified value. It changes no kernel form, HASH_V0 rule, surface or
bootstrap carrier, effect/operation identity, Workspace implementation,
runtime, native compiler, GM.16 report bytes, or predecessor manifest.

## Public command

```text
jac why-effect EFFECT --source FILE
  [--prelude DIR]
  [--syntax auto|surface|bootstrap]
  [--output-format text|json-v1]
  [--diagnostic-format text|json-v1]
```

`EFFECT` is exactly `Fs`, `Net`, or `Secret`, or the exact released lowercase
HASH_V0 identity of one of those effects. It is not resolved through mutable
names. A user effect with the same resolver spelling has a different identity;
GM.16's environment pin rejects that collision as E1400, while requesting its
hash as an authority is E1534. Wrong pinned drivers likewise fail GM.16 before
attribution. Every failure leaves stdout empty, and success/diagnostic formats
are independent.

## Verified-source seam

`Governance_source_check.verified_source` is abstract. `verify_detailed`
performs the existing verification and retains the isolated store/checker,
root name and hash, payload-thunk expression, exact direct/forwarded topology,
and source-member group mappings. `verified_report` recovers the unchanged
GM.16 report; the existing `verify` is exactly a mapping through that accessor.
Consequently existing GM.16 text/JSON and diagnostic behavior remain one path,
not a parallel reimplementation.

## Attribution algorithm

`Governance_why_effect.analyze` traverses application structure, not
`Check.effect_provenance` and not GM.16's broad reference scan. It evaluates
the callee expression and all arguments before attributing invocation, then
follows only:

- exact Workspace v0 operation identities;
- exact source-owned inter-group term references;
- valid source-order `GroupRef` members, including guarded SCCs;
- syntactically direct lambdas; and
- closed first-order external leaves whose parameter/result types transport no
  callable or unresolved type variable and whose closed row contains neither
  Workspace nor the requested raw effect.

Uninvoked references and lambda values are inert. Quote data, including nested
quotes, is inert; only valid level-zero unquote splices are traversed. Cycles
stop on the active source-member stack and a fixed 100,000-node budget fails
closed. Variable, returned, selected, tuple-carried, open external, and other
higher-order callees fail E1535. Reachable local Workspace or requested-effect
handlers fail E1536; unrelated handlers are conservatively inspected.
E1537 and E1538 are defensive verifier-invariant fallbacks: the public command
first requires GM.16 verification, which normally rejects malformed GroupRefs
or staging before attribution, while unexpectedly retained malformed data
still fails E1537 and a traversal beyond 100,000 inspected nodes fails E1538.
The evidence does not claim ordinary verified source can reach E1537.

Direct dry roots produce zero chains. A verified live source with no matching
attributable Workspace application also succeeds with `chains=[]`; that is not
proof the effect is absent at runtime. Each nonempty chain records the root and
source-member path, its public `application_site`, exact Workspace operation,
ordered forwarding layers, truthful direct-live or live-layer leaf, canonical
operation-specific driver, and exact raw effect. Fs selects every reached
read/write chain; Net and Secret select reached fetch chains. An application
site combines the exact source-member identity with a zero-based preorder
ordinal over reachable resolved-kernel applications in that member. Directly
invoked lambda bodies and live splices participate; inert quotes and lambda
values do not. The member-local numbering is carrier-independent and
distinguishes identical repeated calls. Identity and site keys determine
ordering and deduplication.

## Static review facts and claim boundary

Compact JSON uses `jacquard-why-effect-report-v1` and exposes requested effect,
source root, topology, chains, review facts, and evidence limits at the outer
level. The nested `jacquard-governance-review-facts-v1` handoff carries the
frozen Workspace facade and operation set plus every reached operation's exact
raw authority envelope, normalizer, summarizer, simulator, ordered membrane
layers, leaf driver, and driver-introduced raw row. Text projects the same
semantics. Both state `runtime-absence-proof=false` and
`execution-provenance=false`.

The report proves conservative reachability in one fully verified source
artifact. It does not execute code, install a handler, grant authority, prove a
call happened, prove an external action occurred, prove driver correctness,
or turn an empty static result into runtime absence.

## Evidence matrix

Four compiled Alcotest cases cover direct read/write/fetch authority, exact
display/hash selection, distinct deterministic repeated-call sites, zero/dry
reports including an ambiguous dry payload, source-owned Ref and GroupRef paths,
an SCC cycle guard, live unquote, directly invoked lambdas, inert
ref/lambda/nested-quote data, two-forward-layer order,
variable/selected/polymorphic-transport and local-handler refusal, same-name and
driver pinning, both schemas, and explicit claim limits.

`test/cli/why-effect.t` pins the top-level command, direct and forwarded text,
deterministic JSON, repeated-byte equality, `.jac`/`.jqd` parity, display/hash
equivalence, Fs/Net/Secret selection, distinct application ordinals, zero/dry
output, inter-group and SCC path depth, direct-lambda and live/inert staging,
independent formats, empty failure stdout, user-hash E1534, higher-order and
unresolved-polymorphic transport E1535, local-handler E1536, and inherited
E1400 collision and driver-drift refusal. The overlay therefore raises the
successor inventory from 790 to 794 compiled cases and from 47 to 48 cram
transcripts; the 27 documentation examples are unchanged.

## Reproduction

```sh
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp"
export TMPDIR="$PWD/.scratch/tmp"
opam exec -- dune build --root "$PWD" @all
cd test && ../_build/default/test/test_jacquard.exe test \
  governance-why-effect --compact --color=never
cd ..
opam exec -- dune runtest --root "$PWD" test/cli/why-effect.t
opam exec -- dune runtest --root "$PWD" --force
opam exec -- dune build --root "$PWD" @fmt
opam exec -- dune build --root "$PWD" @doc
scripts/release/reproduce-0.1.sh
sha256sum -c docs/release/governed-membranes/GM17B-MANIFEST.sha256
```
