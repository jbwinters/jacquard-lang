# C0-C2 structured-concurrency evidence

`task-schedules.jac` contains two things:

- two checked signatures proving a spawned child's `Net` effect remains visible
  before and after an `async.scope`; and
- one small task expression that spawns two immediate children.

The developer evidence driver runs that exact resolved task expression under
FIFO round-robin, seeded random choice, bounded exhaustive enumeration, and
strict replay. The two-child schedule tree has exactly eight complete worlds.
Every exhaustive world returns `0`, has its own canonical version-1 trace, and
strictly replays byte for byte.

From a source checkout:

```sh
eval "$(opam env)"
opam exec -- dune build @all
sh demos/concurrency/run.sh
```

This is a source-level evidence demo because exhaustive enumeration is a
library/review seam, not a public `jac run` flag. Installed release demos remain
CLI-only. The evidence driver does not add another scheduler or change the
language interface.
