# Structured Concurrency SC.0 Evidence

Status: interface and invariant freeze for D46-D50. Runtime Task values,
scheduler state, scopes, and an Async root handler remain C1 work.

- Reconstruction base: `d3807218823dfc152145e48616c3141c5b05d1ef`
- Evidence overlay: [MANIFEST.sha256](MANIFEST.sha256)
- Authoritative contract: [concurrency.md](../../concurrency.md)

## Frozen identity boundary

The checker-privileged interface is nominal and structural. It recognizes only
the exact resolved `async.spawn` member of this declaration family:

| declaration/member | HASH_V0 identity |
|---|---|
| `Task a = TaskOpaque` | `07791255b44e18c3830038c51396bd3f80cf44a8e89222ff73dc90dd06ec3fb3` |
| `TaskResult a` | `915f69bd6fd8b34c2794b4b0e7ca88f5aafd0187e5c7c36a59091f6d031405ae` |
| `Async a` | `4ff8ce05ab09968163492b3be40fc91381b47dee5fb4b2980f9416d50f38e66f` |
| `async.spawn` | `dae95472328cdc4e38d64b3dd71f49f8b99d1cabbc5a1be603d7d44cc3b0c4a5` |
| `async.await` | `7326d67de02f676afc476e7f16a3b4ee9617293865ffc8dd77ca7f0e9e8e675a` |
| `async.cancel` | `5371011ae9b806265e1f12224cbb5a44bb6aabe7e5396e68eca7babf4c3a93d0` |
| `async.yield` | `3f67a20859f53ca48578469efd2c4bc2956bfa6b37d241fcbf2fe19d1ddf3e6a` |

These hashes are derived from the exact Task carriers, type variable links,
four-operation order/names/modes, and the open enclosing-effect row. They are
not string-prefix or namespace permissions. `Check.is_frozen_async_spawn`
independently revalidates the full resolved structure before charging the
solved child row to a direct call.

## Executable evidence

The `effect-taxonomy` suite exercises the complete privilege mutation matrix:
effect name and variables; operation count, order, every name, and every mode;
spawn thunk arity, result linkage, open/closed/mixed self rows, Task identity
and parameter linkage; await Task and TaskResult identities; and cancel/yield
parameters and results. An otherwise exact non-Async declaration receives no
privilege. The executable documentation separately proves that the exact direct
spawn exposes `{Async, Net}` and rejects a laundering `{Async}` annotation.

The same suite pins the complete canonical effect payload bytes containing the
new row tag `0x38`, the Async declaration/member hashes, and the historical
Abort payload/hash as a `0x36` compatibility baseline. It distinguishes open,
closed, and mixed self rows; checks resolver preservation and malformed-context
E0302/E0501 failures; round-trips through bootstrap printing/reading; and
persists the declaration through store put/get/reopen.

`Concurrency_contract` supplies runtime-free executable relations for strict
task-path formation, lifecycle transitions, waiter registration order,
scheduler-sequenced failure selection, deterministic await-cycle detection,
and FIFO decisions. These freeze C1 obligations without claiming a scheduler.

The overlay also includes every changed semantic source, public interface,
specification, fixture, and test. The integrated effect-linearity manifest is
refreshed with the same semantic additions so the predecessor gate cannot pass
by omitting the new resolver, canonicalizer, checker interface, or concurrency
contract.

## Reconstruction

From this checkout, build a base-plus-overlay copy under repository-local
scratch space:

```sh
base=d3807218823dfc152145e48616c3141c5b05d1ef
dest="$PWD/.scratch/sc0-evidence-copy"
manifest=docs/release/structured-concurrency/MANIFEST.sha256
rm -rf "$dest"
mkdir -p "$dest"
git archive "$base" | tar -x -C "$dest"
mkdir -p "$dest/$(dirname "$manifest")"
cp -p "$manifest" "$dest/$manifest"
awk '!/^#/ && NF == 2 {print $2}' "$manifest" |
while IFS= read -r file_path; do
  mkdir -p "$dest/$(dirname "$file_path")"
  cp -p "$file_path" "$dest/$file_path"
done
```

The SC.0 and integrated predecessor manifest files exclude themselves and each
other to avoid impossible self- and cross-hashes; every semantic file is listed.

## Verification

Run from the successor checkout and the reconstructed copy:

```sh
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp"
export TMPDIR="$PWD/.scratch/tmp"
scripts/release/check-structured-concurrency-manifest.sh
scripts/release/check-effect-linearity-manifest.sh
opam exec -- dune build @all
opam exec -- dune runtest --force
opam exec -- dune fmt
git diff --exit-code
opam exec -- dune build @doc
```

Expected results are zero exits, 568 compiled Alcotest/QCheck cases, 32 cram
transcripts, and 24 doctest examples across 7 documents. The direct-spawn rule
is intentionally narrow: SC.4 still owns higher-order aliases, wrappers, and
returned-closure non-laundering.
