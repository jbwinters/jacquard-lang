# Effect Taxonomy ET.3 Evidence

Status: reconstructible ET.3 overlay on validated ET.2 commit `47d5e8d`.

ET.3 implements D58 without changing the released ET.2 AuditEntry schema. Each
record is exactly one LF-terminated canonical form:

```text
(audit-chain-v1 #PREVIOUS #DIGEST (audit-entry-v1 ...))
```

The embedded entry uses the existing `Printer.print_compact` serialization
already pinned by `audit.entry-code`; the wrapper is not a second AuditEntry
serializer. `DIGEST` is HASH_V0 over the domain bytes
`jacquard-audit-chain-v1\0`, the predecessor's raw 32 bytes, and those entry
bytes. The fixed empty-chain head is
`5a8760f8a958799a0e38154fae7cc086d9a1ee0153ff62451ac1a07f7b0b50d7`.

The three-record fixed golden reconstructs to
`257b42d9957e846671b0a31fc9850e493657e0abc4ea37c26db4bd213152fbd1`.
Both values and every carrier byte are checked into `corpus/golden/`.

## Publication and verification contract

- `jacquard audit genesis` prints the fixed empty head.
- `jacquard audit append LOG ENTRY --previous HASH` verifies the existing log
  against the caller's independently held previous head before writing, appends
  one canonical record plus LF, and prints the new publishable head.
- Appending remains a single-writer operation. It takes a nonblocking advisory
  whole-file lock as a fail-closed race check, but does not claim a competing-
  writer protocol or crash recovery.
- `jacquard governance verify-log LOG --head HASH` reconstructs the chain
  offline and compares it with the independently published head.
- Verification rejects malformed or noncanonical bytes, wrong versions,
  predecessor discontinuities, altered entries or digests, and final head
  mismatches. Tail removal is detectable because the expected head is external
  to the log.
- Every verification failure is a `Diag.t list`; malformed input does not raise.
- Log reads are bounded at 16 MiB and entry reads at 1 MiB. The shared reader
  streams to EOF and compares the opened descriptor and path identity, size,
  mtime, and ctime before and after. Append locks, reads, verifies, seeks, and
  writes the same open file description, with a final pathname-identity check
  before the write. Truncation, growth, replacement, limit overflow, and
  expected I/O exceptions return E1306 before any record write.

## Adversarial evidence

The dedicated `audit-chain` suite pins the fixed genesis and three-entry golden,
clean verification, and deterministic diagnostics for reordered, removed,
duplicated, wrong-version, malformed, altered, noncanonical, and non-LF input.
It also pins stale-head and bounded-read append failure without changing the
log, a direct one-byte mutation witness, 160 sampled one-byte mutations that all
fail without exceptions, and 50 generated valid chains where every sample
contains Evaluated, Consented, and Completed entries and reconstructs to its
expected head. A coordinated sparse-file truncation regression repeatedly
changes a 2 MiB file while the public verifier reads it, pins E1306, and proves
that no expected I/O exception escapes. A lock-coordinated replacement
regression atomically replaces the pathname only after append has locked the
original inode; it pins E1306 and proves that neither the replacement nor the
verified original inode receives the proposed record.

`test/cli/tools.t` independently exercises the public CLI surface: genesis,
bounded and missing entry/log reads with append no-write evidence, three appends
with exact returned heads, successful governance verification, malformed head
rejection, and deterministic failures for tail removal, duplication, a one-byte
entry change, wrong version, and malformed input.

## Reproduction

```sh
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp"
export TMPDIR="$PWD/.scratch/tmp"
opam exec -- dune build --root . @all
opam exec -- dune runtest --root . --force
opam exec -- dune build --root . @fmt
opam exec -- dune build --root . @doc
sha256sum -c docs/release/effect-taxonomy/ET3-MANIFEST.sha256
```

The ET.3 checkout contains 593 compiled Alcotest/QCheck cases and 32 cram
transcript files. The ET.2 `EVIDENCE.md` and `MANIFEST.sha256` remain historical
and unchanged; ET.3 publishes this separate successor overlay.
