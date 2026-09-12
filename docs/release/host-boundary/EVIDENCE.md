# Host boundary evidence

Status: HB.3 publication, September 2026. This pack records what the host
boundary work has shipped, the exact artifacts an adapter pins, and the
evidence behind each claim. It repeats the still-active limits in
[LIMITS.md](LIMITS.md) and records the two open vector decisions in
[DECISION.md](DECISION.md).

## Shipped slices

| Slice | Content | Landed |
|---|---|---|
| HB.0 | ownership and trust contract, `docs/host-boundary.md` | #107 |
| HB.1 | frozen envelopes, framing, limits, vectors, `spec/host-protocol-v0.md` | #108 |
| HB.2a | strict framing and selection codec | #109 |
| HB.2b1 | bounded first-order type and value codecs | #110 |
| HB.2b2 | checked invoke preflight | #111 |
| HB.2b3 | serial session accounting, `docs/host-session-v0.md` | #113 |
| HB.2c | opt-in worker `jacquard host worker`, `docs/host-worker-v0.md` | #114 (main `128fbafa255ba3bb688e4f795d58cb6f09432424`) |
| HB.3a | executable conformance kit, `spec/host-protocol-v0/kit/` | #115 (main `61575c7bcd98c8922e739de647556d1368729ad8`) |

The TS.0 repair that the publication gate required (checked effect payload
constraints preserved through handlers) landed in #112 before the worker.

## Artifacts an adapter pins

| Artifact | SHA-256 at publication |
|---|---|
| `spec/host-protocol-v0/vectors.json` (frozen HB.1) | `9ba1bff8eee0b6dbea6475dc0c7e9cc6313d847ad80bd8d832457115eb1c738a` |
| `spec/host-protocol-v0/kit/fixtures.jac` | `037bb8209ca0344ba0a2cd0fcc16e69f13c8f9b91e3404dc3f3161e351831d80` |
| `spec/host-protocol-v0/kit/kit.json` | `a286328c457696a898aaa6731f0044fb90c78d8657d57270384a76976b070b53` |
| `spec/host-protocol-v0/kit/transcripts.json` | `ebaf590e3d1b7e8399f56de5ad85043ac3658416dd7f0af7b55b9f9f3ce93240` |

Protocol `jacquard-host-v0`, carrier `stdio-u32-json-v0`, Core version
`0.2.0` at the commits above. The recipe
`jacquard run fixtures.jac --store DIR` with the prelude of the same
checkout reproduces every identity in `kit.json`.

## Executable results

- 21 of 21 vector transcripts replay byte-for-byte through the installed
  worker via the deterministic fake host; two consecutive regenerations hash
  identically.
- 20 transcripts conform to their vector expectation. The single recorded
  divergence is `noncanonical-target-hash` (vector E1603, observed E1601);
  see DECISION.md.
- All 5 positive sequences equal their bound HB.1 templates except the
  diagnostic prose fields of two outcome templates, which are listed under
  `diagnostic_prose.drift` in `kit.json`; see DECISION.md.
- All 13 terminal mappings execute with the frozen primary code and terminal
  classification.
- Worker evidence: 23 cases (22 Alcotest cases and one QCheck property) in
  `test/test_host_worker.ml` and
  `test/cli/host-worker.t`, including dead-output and carrier-loss exit
  statuses; kit evidence: 7 cases in `test/test_host_kit.ml`.
- Source inventory at publication: `1014 / 61 / 28` Alcotest-QCheck cases,
  cram transcript files, and documentation examples.

## The first independent adapter

[`jacquard-host`](https://github.com/jbwinters/jacquard-host) (Python,
standard library only) pinned this kit by the SHA-256 values above, vendored
the four files, and replays every transcript against the installed worker
with its own fake host (`python -m jacquard_host.kit`): 21 of 21 transcripts
match their recordings, `noncanonical-target-hash` is reproduced as the
recorded divergence, and no diagnostic prose drift is observed. On the same
pin it built an embedding adapter (Python functions serve a term's `once`
operations by exact identity), a serial loopback socket host, an HTTP/1.1
subset parser written in Jacquard, a host-owned SQLite operation, and an
end-to-end synthetic trial, each independently reviewed and merged. Its
`docs/EVIDENCE.md`, `docs/AUTHORITY.md`, and `docs/CORE-REQUIREMENTS.md`
(`jacquard-host-core-requirements-v1`) are the adapter-side record. The
requirements it reports back to Core, in its words, are: no bytes boundary
value; single-source store population until the store-reopen repair lands;
`--print-sigs` printing a one-item tuple as `(Int)`; `jacquard hash` printing
a type and a same-named constructor without a kind; prelude type identities
recoverable only by hashing prelude files; `Session.request` matching
registry bindings by operation hash only; the pending
`noncanonical-target-hash` decision; no frozen pair for a completed but
unrepresentable result; no host-side handler deadline in the protocol
(recorded as a host limit); and this evidence pack itself. None of them
blocked the adapter; nine name the Core change that would remove a
workaround and the tenth confirms HP0.8 needs nothing.

## Gates

Required contexts on each PR above: Development gate, Native parity (clang),
Native parity (gcc), Governance playground, GM12B exhaustive forwarding
evidence. Independent review: #114 review 1 BLOCK (standard-output carrier
loss) fixed in the same PR, review 2 PASS; #115 review 1 aborted without a
verdict, reviews 2 and 3 PASS.

## Reproduction

```sh
eval "$(opam env)"
opam exec -- dune build @all
NO_COLOR=1 opam exec -- dune runtest
opam exec -- dune exec test/gen_host_kit.exe && git diff --exit-code spec/host-protocol-v0/kit
```

In a nested worktree add `--root .` to each dune command.
