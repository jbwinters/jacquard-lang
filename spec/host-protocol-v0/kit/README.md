# Host protocol v0 conformance kit

This directory turns the frozen HB.1 schema/state vectors in
[`../vectors.json`](../vectors.json) into executable fixtures for the
`jacquard-host-v0` protocol over the `stdio-u32-json-v0` carrier. An adapter
in any language pins this kit, drives the installed `jacquard host worker`,
and must observe exactly the Core frames recorded here.

## Files

- `fixtures.jac`: first-party fixture declarations. Install them once with
  the published recipe, `jacquard run fixtures.jac --store DIR`, using the
  prelude shipped with the same Core release.
- `kit.json`: the manifest. It records the protocol and carrier names, the
  Core version that produced the kit, the recipe, the exact identities of
  every fixture member, the binding from each synthetic 64-digit vector
  identity to a kit member, the hard limits, the fields an adapter owns, and
  every pending decision.
- `transcripts.json`: one entry per positive and hostile vector. Each entry
  lists the host frames in order (or the raw bytes for wire cases), the Core
  frames the worker emitted, the exit status, the observed primary code and
  terminal classification, the host's local refusal for the terminal-phase
  case, and a status of `conforms` or `diverges`.

## Binding

The vectors use synthetic identities so that they can be frozen without a
store. The kit binds them to real content-addressed members:

| Vector identity | Kit member |
|---|---|
| `aaaa…` | `kit-ready : () ->{} ()` |
| `dddd…` | `kit-echo : (Text) ->{KitWorld} Text` |
| `bbbb…` | the `KitWorld` effect |
| `cccc…` | its `send : (Text) -> Text` operation |
| `1111…` | the `Text` type |

Every other synthetic identity in a hostile mutation (for example the extra
capability `eeee…` or the uppercase target) is left as written, because the
case exists to prove that Core rejects it.

## How an adapter uses the kit

1. Pin `protocol`, `carrier`, `core_version`, and the SHA-256 of `kit.json`
   and `transcripts.json` in the adapter's compatibility record.
2. Build the store with the recipe and check that the identities in
   `kit.json` resolve, so the adapter is talking to the same fixtures.
3. For each transcript, start one worker and play the recorded steps in
   order: read one Core frame for each `core_to_host` step and write one host
   frame (or the raw bytes) for each `host_to_core` step. The two negotiation
   frames, `host_select` and `invoke`, are consecutive host steps. Never write
   after a terminal frame has been read: a recorded host step that follows
   the terminal is counted under `host_inputs_skipped_after_terminal`, and the
   `after_terminal` step of the terminal-phase case must be refused locally
   as E1608. Compare the Core frames, exit status, and observed summary with
   the transcript.
4. Compare semantic JSON: key order and insignificant whitespace do not
   matter. Diagnostic prose (`summary`, `cause`, `next_step`, `contrast`) is
   Core-authored human text and is not normative; the schema, domain, code,
   severity, and span are, and an `effect_failure` message must end the first
   diagnostic's cause exactly.
5. Treat any divergence as a protocol or implementation finding. An adapter
   must never normalise its own frames to make a transcript pass.

Fields an adapter owns and may add outside the Core frames are named under
`host_owned` in `kit.json`; nothing inside a Core frame is host-owned.

## The fake host

`test/host_kit.ml` contains the deterministic fake host used to produce and
replay these transcripts. It spawns the installed worker over pipes, writes
host frames only when it is the host's turn, refuses to send after it has
observed a terminal frame (recording the local E1608 the protocol requires),
closes its input after raw wire cases, and records every Core frame, the exit
status, and the bounded operator text. It is evidence tooling, not an adapter
or embedding contract.

## Regeneration and drift

`dune exec test/gen_host_kit.exe` from the repository root rebuilds the store
with the recipe, replays every vector, and rewrites `kit.json` and
`transcripts.json`. `test/test_host_kit.ml` fails when a regenerated
transcript differs from the checked-in one, when a positive sequence stops
matching its bound HB.1 template, when a hostile case stops producing its
expected primary code, or when a divergence appears that is not listed under
`pending_decisions`.

Changing a vector's expected code or shape remains a reviewed protocol
decision, never a mechanical refresh. Two kinds of drift are recorded rather
than resolved here:

- `pending_decisions` lists `noncanonical-target-hash`, whose vector expects
  E1603 while the shipped preflight classifies an uppercase hash as a
  malformed scalar (E1601) under the frozen fail-fast order.
- `diagnostic_prose.drift` lists the outcome diagnostics whose vector prose
  differs from the prose the shipped session layer emits for the same code.
