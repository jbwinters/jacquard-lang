# SC.2: native pure-parallel optimization decision

Status: **declined for the current native runtime** (2026-07-15).

Task 126 made native worker execution optional and conditioned it on a proof
and parity boundary: the compiled artifact must retain the callback's closed
empty effect row; workers must be bounded and joined; result order and failure
selection must remain source ordered; and sanitizer stress plus a benchmark
must pass before the optimization becomes the default. The current backend
does not meet those prerequisites. `parallel.map` and `parallel.both` therefore
remain sequential in both the interpreter and native binaries. There is no
threaded opt-in whose safety could be mistaken for an experimental guarantee.

## Blocking audit

### The emitted artifact has no row proof

The checker proves the public combinators' callback rows are closed and empty,
and Task 125 pins rejection of effectful callbacks. That proof is sufficient
for the language API, but it is not retained at the prospective worker call
site:

- `Check.check_top` records application rows in its mutable statistics context.
- `Store.stamp_tier` can write a member-level `.tier` sidecar, but only the
  separate `jacquard tiers` command does so. `jacquard build` neither requires
  nor reads those sidecars.
- `Native.Compile` lowers resolved kernel expressions into NIR without row or
  proof fields, and specialization can clone `parallel.map` and its callback.
- The emitted C identifies `parallel.map` in a comment for debugging, but
  contains no closed-empty-row certificate tied to the callback invocation.

Recognizing the source name or trusting an optional member sidecar would not
meet the task's requirement. A sound worker path needs a non-forgeable proof
token produced by the successful check, preserved through lowering and
specialization, and asserted where C emission selects worker execution.

### The value runtime is single-threaded

`runtime/jq_alloc.c` explicitly relies on the program thread being the only
allocator. Its small-block slabs and freelists are process globals without
synchronization. `jq_dup` and `jq_drop` increment and decrement ordinary
`uint32_t` reference counts, and their free walk can return blocks to those
global freelists. Passing an input closure or immutable list node between
workers would therefore introduce reference-count and allocator data races;
language immutability does not make the ownership machinery atomic.

The `jq_rt` execution context is also mutable. Generic calls use `apply_n`,
the trampoline uses `tc_fn` and `tc_args`, and handler/frame state shares the
same structure. A pure callback may still take the generic application path,
so its empty row does not license concurrent mutation of one `jq_rt`.

### Runtime failures cannot be joined deterministically

`jq_runtime_error` writes to stderr and immediately calls `exit(2)`. That is
correct for one program thread, but it cannot report worker failures as data.
If two callbacks fail, host scheduling would choose which diagnostic wins and
the process would exit before all workers join. Preserving `parallel.map`'s
first failing input and `parallel.both`'s left-before-right failure requires a
recoverable worker-result ABI, ordered selection after every worker joins, and
cleanup of all produced values. None exists today.

These are independent blockers. Adding a mutex around the allocator would not
create proof retention or deterministic failure translation, while copying a
`jq_rt` would not make shared reference counts safe.

## Evidence and benchmark

Run the reproducible fallback lane from the repository root:

```sh
eval "$(opam env)"
export JACQUARD="$PWD/_build/default/bin/main.exe"
export JACQUARD_PRELUDE="$PWD/prelude"
export JACQUARD_RUNTIME="$PWD/runtime"
JACQUARD_PARALLEL_EVIDENCE_ITERATIONS=20 \
JACQUARD_PARALLEL_TSAN=1 \
JACQUARD_PARALLEL_BENCH=1 \
JACQUARD_PARALLEL_BENCH_RUNS=31 \
  scripts/native-parallel-evidence.sh
```

The lane compares interpreter and native stdout, stderr, and exit status for a
successful stress program and for source-ordered failures. The map fixture has
two elements that fail differently—division first, modulo second—and the both
fixture has the same distinguishable left/right failures. The lane asserts the
division diagnostic wins in both cases, repeats the native success case, and
then repeats exit/stdout/stderr parity for all three fixtures under
ASAN/LeakSanitizer and, optionally, TSAN. Before timing, it also byte-compares
the paired `list.map` and `parallel.map` benchmark outputs. The fixtures live
under `test/native-parallel/`. Sanitizer parity here proves the sequential
fallback stays clean and deterministic; it is deliberately not evidence for a
worker path that does not exist.

Recorded environment and result on 2026-07-15 at base `aef42e9`:

```text
Linux 6.14.0-37-generic x86_64
AMD Ryzen 9 7950X3D, 16 cores / 32 hardware threads
clang 18.1.3, OCaml 5.1.1, Dune 3.24.0
native flags: repository default -std=c11 -O2 -flto

success: interpreter/native exit/stdout/stderr identical, exit 0
fail-map: both callbacks fail distinctly; first division-by-zero wins, exit 2
fail-both: both thunks fail distinctly; left division-by-zero wins, exit 2
stress: 20 identical native runs
ASAN+LeakSanitizer: interpreter-identical exit/stdout/stderr for all 3 fixtures
TSAN: interpreter-identical exit/stdout/stderr for all 3 fixtures

1,000,000-element native map/fold, warm binaries:
benchmark sequential/hint stdout and stderr: byte-identical before timing
benchmark stdout SHA-256: d1f60dec073c74b9486d3f58d9d1d618cd40272b0de8d74faa34c72b383a51fe
list.map reference: 79.521 ms median of 31
parallel.map hint: 99.893 ms median of 31
```

The timing does not compare threads—there is no sound threaded candidate to
measure. It establishes the pre-optimization baseline and shows no reason to
enable a distinct default path today: the current hint wrapper is about 26%
slower on this workload. Future measurements must use the harness's paired
fixtures, record the toolchain and host, preserve byte identity, and show a
repeatable benefit before any worker path becomes default.

## Definition-of-done disposition

| Task 126 condition | Current disposition |
|---|---|
| Static empty-row proof retained in compiled artifacts | Not met; therefore no worker execution is emitted. |
| Bounded workers and join-all | Not applicable to the sequential fallback; required before reconsideration. |
| Ordered results and deterministic failures | Preserved by sequential execution; two distinguishable failures pin map source-first and both left-first selection. |
| Interpreter remains sequential | Preserved. |
| Sequential fallback on unsupported targets | Preserved on every target; it is the only path. |
| Benchmark before enabling by default | Recorded above; threaded default declined. |
| Native/stress/ASAN/TSAN parity | Exit/stdout/stderr parity is exercised for success and both ordered-failure fixtures on the shipped sequential path; worker sanitizer evidence remains a future gate. |
| No effectful callback on a worker | Vacuously true because there are no workers; Task 125's checker tests continue to reject such callbacks. |

This is a completed no-go decision, not an assertion that threads are
impossible. Reopening SC.2 requires all three architectural changes: proof-
carrying native lowering, a thread-safe value/execution ownership design, and
recoverable ordered worker failures. Only then should a bounded pool, target
fallbacks, worker stress under ASAN/TSAN, and default-enable benchmarks be
implemented.
