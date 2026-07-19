SC.3 publishes TaskResult as ordinary data with interpreter/native parity and
keeps Task's carrier scheduler-private. SC.9 gives the default interpreter a
deterministic structured scheduler for the exact frozen Async declaration.

  $ export JACQUARD_PRELUDE=../../prelude
  $ export JACQUARD_RUNTIME=../../runtime
  $ export CC=clang

  $ cat > results.jqd <<'EOF'
  > (tuple
  >   (app (var done) (lit 42))
  >   (app (var failed) (lit "stable"))
  >   (var cancelled))
  > EOF
  $ jacquard run results.jqd > interpreter.out
  $ jacquard build results.jqd -o results-native > /dev/null
  $ ./results-native > native.out
  $ diff interpreter.out native.out && cat native.out
  (done(42), failed("stable"), cancelled)

The private constructor cannot be recovered by its pinned hash through either
checker path.

  $ cat > private-task.jqd <<'EOF'
  > (ref #9b4eaa5e872fa3f768c71fc4cba4d3262a9ebf8a719f0cfb78f22fa9eade4310 con)
  > EOF
  $ jacquard run private-task.jqd 2>&1 | sed 's/private-task.jqd:[0-9]*:[0-9]*-[0-9]*/private-task.jqd:LINE:SPAN/'
  private-task.jqd:LINE:SPAN: error[E0907]: A scoped task or channel handle is invalid
    Cause: the opaque scoped-handle carrier is scheduler-private and cannot be constructed by Jacquard code
    Next step: Use the trusted scheduler operation that creates this opaque scoped handle.

SC.14 applies the same sealed boundary to ChannelHandle.

  $ cat > private-channel.jqd <<'EOF'
  > (ref #dc7a12f5fc0476b674d52535e9895220edf41f2a017b1dd97fc078950a3dbb36 con)
  > EOF
  $ jacquard run private-channel.jqd 2>&1 | sed 's/private-channel.jqd:[0-9]*:[0-9]*-[0-9]*/private-channel.jqd:LINE:SPAN/'
  private-channel.jqd:LINE:SPAN: error[E0907]: A scoped task or channel handle is invalid
    Cause: the opaque scoped-handle carrier is scheduler-private and cannot be constructed by Jacquard code
    Next step: Use the trusted scheduler operation that creates this opaque scoped handle.

The default interpreted path now routes Async through that scheduler. This
does not grant world authority and does not add native root scheduling.

  $ cat > yield.jqd <<'EOF'
  > (app (var async.yield))
  > EOF
  $ jacquard run yield.jqd 2>&1; echo "exit $?"
  ()
  exit 0

Channel is likewise interpreted scheduler infrastructure, not a native root
runtime.

  $ cat > channel-roundtrip.jqd <<'EOF'
  > (match (app (var channel.open) (lit 1))
  >   (clause (pcon ok (pvar channel))
  >     (let nonrec (pwild) (app (var channel.send) (var channel) (lit 7))
  >       (app (var channel.recv) (var channel))))
  >   (clause (pcon err (pvar error)) (app (var err) (var error))))
  > EOF
  $ jacquard run channel-roundtrip.jqd 2>&1; echo "exit $?"
  ok(7)
  exit 0

  $ cat > channel-open.jqd <<'EOF'
  > (app (var channel.open) (lit 0))
  > EOF
  $ jacquard build channel-open.jqd -o channel-native 2>&1 | sed 's/channel-open.jqd:[0-9]*:[0-9]*-[0-9]*/channel-open.jqd:LINE:SPAN/'; echo "exit $?"
  native: compiled 1 unit(s)
  exit 0
  $ ./channel-native 2>&1; echo "exit $?"
  error[E0814]: The program requires an effect that was not granted
    Cause: This program requires channel [concurrency/none] — communicate typed values between structured tasks, which is not granted (performed via `channel.open`).
    Next step: handle the effect in the program (this effect is pure and cannot be granted)
  exit 3
