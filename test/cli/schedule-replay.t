SC.10 pins the canonical scheduler trace, strict replay, and explicit forks.

  $ export JACQUARD_PRELUDE=$PWD/../../prelude
  $ cat > replay.jqd <<'EOF'
  > (let nonrec (pvar child)
  >   (app (var async.spawn)
  >     (lam ()
  >       (let nonrec (pwild) (app (var async.yield))
  >         (let nonrec (pwild) (app (var print) (lit "child-world"))
  >           (lit 7)))))
  >   (let nonrec (pvar result) (app (var async.await) (var child))
  >     (lit 99)))
  > EOF

Record and replay produce the same user output and byte-identical canonical traces.

  $ jacquard run replay.jqd --allow console --schedule-record recorded.trace > recorded.out
  $ jacquard run replay.jqd --allow console --schedule-replay recorded.trace --schedule-record replayed.trace > replayed.out
  $ cmp recorded.out replayed.out
  $ cmp recorded.trace replayed.trace
  $ cat recorded.out
  child-world99
  $ cat recorded.trace
  jacquard-schedule format=1 scheduler=fifo-round-robin-v0 program=007a67e146bd86bc6c0b591bd4eeedec828b1a0c6603134edd5c17dc5382f3af policy=fail-fast max-tasks=1024 max-decisions=100000 fork=-
  create scope=0 task=0#0 parent=-
  decision sequence=0 runnable=0#0 chosen=0#0 operation=async.spawn
  create scope=0 task=0#1 parent=0#0
  decision sequence=1 runnable=0#1,0#0 chosen=0#1 operation=async.yield
  decision sequence=2 runnable=0#0,0#1 chosen=0#0 operation=async.await
  decision sequence=3 runnable=0#1 chosen=0#1 operation=routed:28570e6bcdeb8646a90b31971204be7007f658bee65154b96e587c47a6585d5e
  decision sequence=4 runnable=0#1 chosen=0#1 operation=return
  decision sequence=5 runnable=0#0 chosen=0#0 operation=return

Unversioned, unknown-version, non-canonical, and impossible logs fail closed.

  $ tail -n +2 recorded.trace > legacy.trace
  $ jacquard run replay.jqd --allow console --schedule-replay legacy.trace > legacy.out 2> legacy.err; echo "exit $?"
  exit 1
  $ test ! -s legacy.out
  $ grep -F 'unversioned schedule traces are unsupported' legacy.err
  error[E0908]: invalid schedule trace: unversioned schedule traces are unsupported
  $ sed '1s/format=1/format=2/' recorded.trace > unknown.trace
  $ jacquard run replay.jqd --allow console --schedule-replay unknown.trace > unknown.out 2> unknown.err; echo "exit $?"
  exit 1
  $ test ! -s unknown.out
  $ grep -F 'unsupported format version 2' unknown.err
  error[E0908]: invalid schedule trace: unsupported format version 2
  $ printf '%s' "$(cat recorded.trace)" > noncanonical.trace
  $ jacquard run replay.jqd --allow console --schedule-replay noncanonical.trace > noncanonical.out 2> noncanonical.err; echo "exit $?"
  exit 1
  $ test ! -s noncanonical.out
  $ grep -F 'canonical trace must end with LF' noncanonical.err
  error[E0908]: invalid schedule trace: canonical trace must end with LF
  $ sed 's/runnable=0#1,0#0 chosen=0#1/runnable=0#1 chosen=0#0/' recorded.trace > impossible.trace
  $ jacquard run replay.jqd --allow console --schedule-replay impossible.trace > impossible.out 2> impossible.err; echo "exit $?"
  exit 1
  $ test ! -s impossible.out
  $ grep -F 'decision 1 chooses 0#0 outside its runnable queue' impossible.err
  error[E0908]: invalid schedule trace: decision 1 chooses 0#0 outside its runnable queue

Input is bounded incrementally by both transport ceilings and declared bounds.

  $ sed '1s/max-tasks=1024 max-decisions=100000/max-tasks=1 max-decisions=1/' recorded.trace | head -1 > too-many-lines.trace
  $ printf 'create scope=0 task=0#0 parent=-\ndecision sequence=0 runnable=0#0 chosen=0#0 operation=return\ndecision sequence=1 runnable=0#0 chosen=0#0 operation=return\n' >> too-many-lines.trace
  $ jacquard run replay.jqd --allow console --schedule-replay too-many-lines.trace > line-limit.out 2> line-limit.err; echo "exit $?"
  exit 1
  $ test ! -s line-limit.out
  $ grep -F 'more than 3 lines permitted by max-tasks/max-decisions' line-limit.err
  error[E0908]: invalid schedule trace: schedule trace has more than 3 lines permitted by max-tasks/max-decisions
  $ sed '1s/max-tasks=1024 max-decisions=100000/max-tasks=1 max-decisions=1/' recorded.trace | head -1 > too-long.trace
  $ awk 'BEGIN { for (i = 0; i < 1048577; i++) printf "x"; printf "\n" }' >> too-long.trace
  $ jacquard run replay.jqd --allow console --schedule-replay too-long.trace > byte-limit.out 2> byte-limit.err; echo "exit $?"
  exit 1
  $ test ! -s byte-limit.out
  $ grep -F 'schedule trace line exceeds 1048576-byte limit' byte-limit.err
  error[E0908]: invalid schedule trace: schedule trace line exceeds 1048576-byte limit

Missing, extra, and reordered events also fail closed rather than falling back.

  $ sed '$d' recorded.trace > missing.trace
  $ jacquard run replay.jqd --allow console --schedule-replay missing.trace > missing.out 2> missing.err; echo "exit $?"
  exit 2
  $ grep -E 'ended before decision 5|missing' missing.err | head -1
  error[E0908]: schedule replay drift: missing decision 5 at trace EOF
  $ { cat recorded.trace; echo 'decision sequence=6 runnable=0#0 chosen=0#0 operation=return'; } > extra.trace
  $ jacquard run replay.jqd --allow console --schedule-replay extra.trace > extra.out 2> extra.err; echo "exit $?"
  exit 1
  $ grep -F 'terminal task 0#0 reappears at decision 6' extra.err
  error[E0908]: invalid schedule trace: terminal task 0#0 reappears at decision 6
  $ sed 's/sequence=2/sequence=9/' recorded.trace > reordered.trace
  $ jacquard run replay.jqd --allow console --schedule-replay reordered.trace > reordered.out 2> reordered.err; echo "exit $?"
  exit 1
  $ grep -F 'decision sequence 2 was expected, found 9' reordered.err
  error[E0908]: invalid schedule trace: decision sequence 2 was expected, found 9

Forking at decision 1 records the provenance choice in the new header. The
forked trace is itself strict-replayable and byte-identical on replay.

  $ jacquard run replay.jqd --allow console --schedule-replay recorded.trace --schedule-fork '1=0#0' --schedule-record fork.trace > fork.out
  $ head -1 fork.trace
  jacquard-schedule format=1 scheduler=fifo-round-robin-v0 program=007a67e146bd86bc6c0b591bd4eeedec828b1a0c6603134edd5c17dc5382f3af policy=fail-fast max-tasks=1024 max-decisions=100000 fork=1:0#0
  $ sed -n '4,7p' fork.trace
  create scope=0 task=0#1 parent=0#0
  decision sequence=1 runnable=0#1,0#0 chosen=0#0 operation=async.await
  decision sequence=2 runnable=0#1 chosen=0#1 operation=async.yield
  decision sequence=3 runnable=0#1 chosen=0#1 operation=routed:28570e6bcdeb8646a90b31971204be7007f658bee65154b96e587c47a6585d5e
  $ jacquard run replay.jqd --allow console --schedule-replay fork.trace --schedule-record fork-replayed.trace > fork-replayed.out
  $ cmp fork.out fork-replayed.out
  $ cmp fork.trace fork-replayed.trace

An operation drift is rejected before the routed callback can print.

  $ sed 's/routed:28570e6bcdeb8646a90b31971204be7007f658bee65154b96e587c47a6585d5e/routed:38570e6bcdeb8646a90b31971204be7007f658bee65154b96e587c47a6585d5e/' recorded.trace > drift.trace
  $ jacquard run replay.jqd --allow console --schedule-replay drift.trace > drift.out 2> drift.err; echo "exit $?"
  exit 2
  $ test ! -s drift.out
  $ grep -F 'decision 3 operation expected' drift.err
  error[E0908]: schedule replay drift: decision 3 operation expected routed:38570e6bcdeb8646a90b31971204be7007f658bee65154b96e587c47a6585d5e, found routed:28570e6bcdeb8646a90b31971204be7007f658bee65154b96e587c47a6585d5e

Replay path failures use Jacquard diagnostics, and record writes still happen
only after the program has completed successfully.

  $ jacquard run replay.jqd --allow console --schedule-replay no-such.trace > missing-path.out 2> missing-path.err; echo "exit $?"
  exit 1
  $ test ! -s missing-path.out
  $ grep -F 'cannot read schedule trace no-such.trace: No such file or directory' missing-path.err
  error[E0908]: cannot read schedule trace no-such.trace: No such file or directory
  $ mkdir unreadable.trace
  $ jacquard run replay.jqd --allow console --schedule-replay unreadable.trace > unreadable.out 2> unreadable.err; echo "exit $?"
  exit 1
  $ test ! -s unreadable.out
  $ grep -F 'cannot read schedule trace unreadable.trace: Is a directory' unreadable.err
  error[E0908]: cannot read schedule trace unreadable.trace: Is a directory
  $ mkdir record-target
  $ jacquard run replay.jqd --allow console --schedule-record record-target > write-failure.out 2> write-failure.err; echo "exit $?"
  exit 1
  $ cat write-failure.out
  child-world99
  $ grep -F 'cannot write schedule trace record-target: Is a directory' write-failure.err
  error[E0908]: cannot write schedule trace record-target: Is a directory
  $ jacquard run replay.jqd --allow console --schedule-record /dev/full > flush-failure.out 2> flush-failure.err; echo "exit $?"
  exit 1
  $ cat flush-failure.out
  child-world99
  $ grep -F 'cannot write schedule trace /dev/full: No space left on device' flush-failure.err
  error[E0908]: cannot write schedule trace /dev/full: No space left on device
