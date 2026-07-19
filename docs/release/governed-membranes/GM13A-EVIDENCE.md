# Governed Membranes GM.13A Evidence

Status: candidate reconstructible GM.13A overlay on exact base
`e20ebcf33c2eb0c5f01212c193e5a28e616aba45`.

## Context

The released `GovernanceApprovalV1` gate binds a Decision to the exact
GovernanceProposal, but its shipped handler is intentionally scripted evidence.
It does not authenticate a reviewer, make a Decision globally fresh, or stop a
previously returned Decision from being supplied again. A production workflow
therefore needs durable host state between the consent service and the gate.

GM.13A adds that storage core as a public OCaml module. It is independently
useful to a trusted host and changes no Jacquard language form, effect, builtin,
surface syntax, canonical serializer, or runtime grant. The kernel remains 27
forms. `GovernanceApprovalV1`, `governance-proposal-v0`, `approved-v1`,
`denied-v1`, `escalate-v1`, and `HASH_V0` retain their released identities.

## Canonical journal and physical commit

The fixed genesis is HASH_V0 of this exact Code:

```text
(governance-approval-queue-genesis-v1)
```

Its pinned identity is:

```text
a830520c64d4dd55483b1829c289866e74fdec839a3fc12d6fcdc6da760e10ed
```

One logical transition occupies two canonical LF-terminated lines. The record
envelope carries a record ID and this exact semantic subject:

```text
(governance-approval-queue-record-v1 (hash #PREVIOUS) EVENT)
```

The record ID is the unchanged HASH_V0 of that subject. A separate
`governance-approval-queue-commit-v1` line names the record ID. The writer
appends and syncs the record line first, then appends and syncs the commit line.
Before any successful existing-file mutating-API result other than Busy,
including an exact retry, stale observation, pending delivery, or clean
recovery, it syncs the file and its parent directory and rechecks pathname
identity. Missing-file recovery returns the fixed empty genesis without an I/O
barrier because no queue inode exists. The existing-file barrier prevents a
retry from acknowledging a prior writer's complete but unsynced commit or an
unsynced newly created filename. The committed head is the last record ID; a
fixed Submit fixture pins head
`2a2550aa6127b030dba0b45605ed3b5fac30a1e829693d685b9b8a7e801f13ea`.
Fixed Decide and Consume fixtures respectively pin heads
`8b9b2196ad07264e45bb5abd11be5f9cd20a5a8853fc25c9a835079872b54d36`
and `2537e339b618dd166867ace0deb3dd370aea3f8b26bd0ca53d0582f6ee57b808`.

The separate commit line is load-bearing. Restart may recognize only these
suffixes after the last fully verified commit boundary:

- a non-LF suffix that is either a prefix of, or starts with, the exact
  `governance-approval-queue-record-envelope-v1` carrier prefix;
- one complete, valid record line lacking its commit; or
- that record plus a non-LF prefix of its exact commit line.

Locked mutation or explicit recovery truncates such a suffix and syncs the
truncation before continuing. Strict string verification rejects every tail,
while read-only inspection reports a recognized tail without changing it.
An LF-terminated malformed record, a full malformed or mismatched commit,
arbitrary trailing bytes, and every corruption at or before a commit boundary
fail closed.

## State and authorization

Submit accepts an explicit carried Proposal ID, the exact
`governance-proposal-v0` semantic Code, and nonempty sorted unique allowed host
principals. It recomputes Proposal HASH_V0 before taking the lock. The allowed
principals remain queue metadata and never enter Proposal identity. An exact
Submit retry is a no-op; the same ID with different queue metadata conflicts.

Decide accepts a proposal ID, an authenticated actor supplied by the host, and
one exact released Decision Code. The actor must occur in the durable allowed
set. Approved and Denied also require the Decision approver to equal that
actor. Escalate has no approver field, so the event stores its authenticated
actor beside the unchanged Decision Code. An exact Decide retry is a no-op; a
different durable Decision conflicts.

Consume deliberately takes only the proposal ID. Under the same lock it
verifies the entire journal, resolves the one immutable Decision, recomputes
its ID, appends `Consume(proposal-id, decision-id)`, syncs the commit, and then
returns the exact Decision plus ID. Requiring a caller-supplied expected ID
would introduce a lookup/consume race. Every Decision variant is delivered
once. A crash after the Consume commit may strand the result, but restart sees
Stale and cannot queue-deliver it again. Administrative inspection retains the
historical Proposal, actor, Decision, and Decision ID; stale state cannot be
reset by Submit or Decide.

## Locking, I/O, and evidence

Every file operation first takes a nonblocking PID-aware process-local guard,
then one nonblocking exclusive whole-file lock. The local guard closes POSIX
`lockf`'s same-process Domain gap; its PID owner can be replaced safely in a
forked child, which still has to acquire the kernel lock. Busy is a typed
outcome and performs no mutation.

Under both guards, reads are bounded at 16 MiB, the complete committed chain
and transition history are verified, and the descriptor is repeatedly compared
with the pathname using `lstat` device and inode identity. Symlinks, FIFOs,
oversized inputs, disappearing or replaced paths, unsafe reads, and descriptor
close failures fail with E1526. Hard links to the same regular inode remain
valid. This is a local POSIX advisory-lock contract with a trusted, stable
parent directory. Pathname identity checks are inherently subject to a final
TOCTOU window against an actor that can rename entries concurrently; no hostile
directory actor, distributed filesystem, or writer that ignores advisory locks
is claimed.

The thirteen-case compiled suite covers:

- fixed genesis, Submit/Decide/Consume heads, Proposal and Decision identities,
  and two-line framing;
- genuine missing-path creation, exact `0600` mode, restart inspection, and
  exact retry through the `O_EXCL` path;
- Pending, each Decision variant, exact retries, drift, conflicts, and stale
  non-reset behavior;
- allowed actors, wrong actors, Decision/actor mismatch, and Escalate actor
  evidence;
- strict committed-chain verification, three recognized restart suffixes,
  explicit recovery, arbitrary-tail and complete noncanonical-line refusal,
  mismatched commits, committed record mutation, committed illegal transitions,
  and malformed-known versus unsupported event versions;
- restart-visible stale evidence and exact Decision identity;
- competing process and Domain consumers, with exactly one delivery and one
  stale result after Busy retry;
- nonblocking lock contention, FIFO, symlink, 16 MiB bound, and pathname
  replacement without an acknowledged mutation; and
- forged Proposal identity, stale Decision identity, noncanonical principals,
  metadata invariance, and an empty outcome-status refusal.

Kernel-level deterministic write/fsync failure injection is not part of this
slice. Append and sync exceptions return E1526 and never acknowledge the
transition; crash-prefix/restart states are exercised through the physical
record/commit fixtures. A later fault-injection lane must test each syscall
site without adding a production fault seam.

## Slice boundary

This module does not authenticate a person, evaluate policy, synthesize or
rebind a Decision, install `GovernanceApprovalV1`, write Audit, invoke a
driver, or claim exactly-once outside-world action. In particular it does not
prove that consent was audited before an action or that a queue commit and
Audit entry share one failure boundary.

GM.13B remains required: add the narrowly scoped trusted host bridge, connect
queue delivery to the exact live gate/Audit sequence, and land hostile
gate/approval/audit/restart ordering evidence. No generic host-handler
injection surface and no production use of the scripted handler are authorized.
GM.13 is therefore not complete at GM.13A.

## Reproduction

```sh
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp"
export TMPDIR="$PWD/.scratch/tmp"
opam exec -- dune build --root "$PWD" @all
opam exec -- dune runtest --root "$PWD" --force
opam exec -- dune build --root "$PWD" @fmt
opam exec -- dune build --root "$PWD" @doc
sha256sum -c docs/release/governed-membranes/GM13A-MANIFEST.sha256
```
