SC.3 publishes TaskResult as ordinary data with interpreter/native parity, but
keeps Task's carrier scheduler-private. Async has no ambient root handler yet.

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
  private-task.jqd:LINE:SPAN: error[E0907]: the Task opaque carrier is scheduler-private and cannot be constructed by Jacquard code
    hint: Task handles are created only by async.spawn inside a structured scheduler scope

Without a scheduler handler, Async fails cleanly instead of acquiring ambient
authority or silently running a child.

  $ cat > yield.jqd <<'EOF'
  > (app (var async.yield))
  > EOF
  $ jacquard run yield.jqd 2>&1; echo "exit $?"
  error[E0814]: this program requires the `async` effect, which is not granted (performed via `async.yield`)
    hint: handle the effect in the program (this effect is pure and cannot be granted)
  exit 3
