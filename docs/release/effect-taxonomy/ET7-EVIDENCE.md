# Effect Taxonomy ET.7 Evidence

Status: reconstructible ET.7 overlay on the validated ET.6 implementation.

ET.7 adds four ring-3 handlers for the released once `Approval.ask` operation:

- `approval.console` recomputes the Proposal identity, prints one canonical
  `approval-request-v1` line with the exact hash before the ordered authority,
  then recognizes only the exact input `approve` as consent.
- `approval.scripted` consumes explicit fixture Decisions in order. It validates
  each Decision against the current Proposal and throws on a stale binding or
  exhausted fixture; the handler does not synthesize `Approved`.
- `approval.dry-run` recomputes the Proposal identity and always resumes with
  `Escalate`. Simulation therefore cannot create consent evidence.
- `approval.policy-auto` recomputes the Proposal identity and approves only an
  already-`Allow` verdict. `Ask` and `Simulate` escalate; `Block` denies.

All validation failures stop before the protected continuation resumes. The
handlers expose `Throw` in their inferred rows so callers must handle this
fail-closed path explicitly. Queue-backed approvals shared across separate
workflow invocations remain membrane work; ET.7's scripted list is scoped to
one handler invocation.

## Evidence

The `approval` Alcotest suite has 11 cases. Four ET.7 cases pin deterministic
console rendering and its three response branches, explicit scripted
Approved/Denied/Escalate inputs, scripted exhaustion and stale-decision
rejection, mandatory dry-run escalation, policy handling for all four Verdict
constructors, and malformed Proposal rejection by every handler.

`test/cli/approval-handlers.t` is the public `.jac` transcript. It pins the
console prompt bytes, common proposal hash across all Decisions, dry-run and Ask
escalation, explicit scripted consent, console consent, and exhaustion. The
`stdlib-handler-policy` doctest uses `approval.dry-run` directly and handles its
validation-failure row. `test/cli/tiers.t` records the four new Approval handler
clauses and their once-resumption shapes.

The resulting checkout inventory is 604 compiled Alcotest/QCheck cases, 33
cram transcript files, and 22 documentation examples.

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
sha256sum -c docs/release/effect-taxonomy/ET7-MANIFEST.sha256
```
