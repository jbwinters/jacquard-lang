# Governed Membranes GM.4 Evidence

Status: reconstructible GM.4 pure-law overlay on validated GM.3 base
`f813d11`.

GM.4 turns charter §15's pure policy claims into separately discoverable,
hermetic Warp properties. It changes no governance carrier, encoder, verdict
function, kernel form, effect, handler, driver, or world boundary. GM.3 remains
the implementation under test; this overlay adds executable evidence.

## Hermetic governance suite

`test/cli/governance-policy-laws.jqd` exposes nine independent `Prop` values:

- risk monotonicity;
- confidence monotonicity;
- minimum-confidence-threshold tightening;
- Forbidden absorption in live and dry policy;
- dry-run totality, including explicit NoSimulation;
- risk-threshold policy tightening;
- Call hash stability under formatting-equivalent Code and changed summary;
- Call hash sensitivity to operation, arguments, authority, and preconditions;
  and
- live, dry, and stored BoundPolicy mismatch rejection.

The suite also exposes an exact numeric-edge `Case` with six checks. It pins
the adjacent representable values below and above `0.5`, equality at `0.5`,
inclusive `0.0` and `1.0`, representative finite values outside `[0,1]`, NaN,
positive infinity, and negative infinity.

Every property has the closed `{Dist, Check}` row required by Warp's hermetic
lane. No property requires a grant, world test, handler, audit sink, simulator
driver, or live driver. Failure labels render the full policy threshold and
confidence values plus canonical policy hashes. Call properties render both
Call IDs; BoundPolicy failure labels render carried and recomputed hashes.

## Exhaustive supports

The generators enumerate all ten ordered `(auto-up-to, ask-up-to)` pairs, all
four risk values, both simulator states where relevant, and the representative
confidence grid `0.0, 0.25, 0.5, 0.75, 1.0`. The confidence-threshold law
separately enumerates all 25 ordered minimum-confidence pairs under the
representative `Low`/`High` risk policy, all four risks, and the same five
observed confidences. Under the default 10,000 exploration budget,
`jac test --exhaustive` reports:

```text
BoundPolicy mismatch rejection   150 cases
Call hash sensitivity             20 cases
Call hash stability                5 cases
confidence monotonicity         1000 cases
confidence threshold tightening  500 cases
dry-run totality                   40 cases
Forbidden absorption             500 cases
policy tightening               2000 cases
risk monotonicity               4000 cases
exact numeric edges                6 checks
```

The same file passes the normal sampled lane with 100 cases per property and
seed 145. Normal and exhaustive property proofs use distinct cache keys; the
exact unit case is shared. A second run is a full cache hit in both modes, and
all nine exhaustive properties render as cached proofs.

## Deliberate mutation evidence

`test/cli/props.t` copies the suite inside Cram's scratch directory and changes
only the first risk-order comparison from `int.lte?` to `int.gte?`. Exhaustive
Warp rejects that copy:

```text
FAIL gm4-risk-monotonicity/risk monotonicity (prop: falsified exhaustively)
  - risk monotonicity: policy={auto=Low,ask=Low,min-confidence=0.0,hash=4495856b093db12ce1add61c7aa1a3ace0a69223f11f3dca17176a18bcbcbe6e}, lhs={risk=Low,confidence=0.0,verdict=Allow}, rhs={risk=Medium,confidence=0.0,verdict=Block}
```

It then independently inverts the minimum-confidence ordering in a second
scratch copy. Warp rejects the exact boundary where the lower threshold allows
and the higher threshold asks:

```text
FAIL gm4-confidence-threshold-tightening/confidence threshold tightening (prop: falsified exhaustively)
  - confidence threshold tightening: tight=policy={auto=Low,ask=High,min-confidence=0.0,hash=3c364878390289d3d83a5162d876945b9285139665b54098adf587d9855e329e},loose=policy={auto=Low,ask=High,min-confidence=0.25,hash=e6869e7318d2ffa8ef842c28b54f5185f195d4220c5a2d8cafac6c7086acf900},risk=Low,confidence=0.0,tight-verdict=Allow,loose-verdict=Ask
```

Neither mutation is applied to the committed fixture. The transcript is both
the detection proof and the evidence that the source tree retains the valid
law.

## Reproduction

```sh
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp"
export TMPDIR="$PWD/.scratch/tmp"
opam exec -- dune build --root . @all
opam exec -- dune runtest --root . test/cli/props.t --force
_build/default/bin/jac test test/cli/governance-policy-laws.jqd \
  --seed 145 --no-cache
_build/default/bin/jac test test/cli/governance-policy-laws.jqd \
  --exhaustive --no-cache
opam exec -- dune runtest --root .
opam exec -- dune build --root . @fmt
sha256sum -c docs/release/governed-membranes/GM4-MANIFEST.sha256
```

Historical GM.1-GM.3 evidence manifests remain unchanged. GM.4 publishes a
separate complete overlay.
