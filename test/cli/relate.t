RW.3 exposes deterministic schedule relation as a narrow root-driven command.
Its help keeps FILE, --vary, and --seed required and does not inherit unrelated
run options.

  $ export JACQUARD_PRELUDE=../../prelude
  $ jacquard relate --help=plain
  NAME
         jacquard-relate - Run a .jac surface or .jqd bootstrap file under
         distinct deterministic schedules and compare complete result and
         routed-root transcripts. Console input is captured in run 1 and
         replayed by ordinal in later runs.
  
  SYNOPSIS
         jacquard relate [OPTION]… FILE
  
  OPTIONS
         --allow=EFFECT
             Grant an effect at the root (repeatable), e.g. --allow console
             --allow eval.
  
         --diagnostic-format=FORMAT (absent=text)
             Diagnostic rendering contract: text (default) or json-v1 (one
             canonical JSON object per line on the existing diagnostic stream).
  
         --prelude=DIR
             Prelude directory (default: $JACQUARD_PRELUDE or ./prelude).
  
         --seed=SEED (required)
             Required root seed for reproducible relational runs and Dist
             sampling.
  
         --syntax=SYNTAX (absent=auto)
             Source or rendering syntax: auto selects surface for .jac files
             and bootstrap otherwise; explicit values are surface/jac or
             bootstrap/jqd.
  
         --vary=KIND (required)
             Required variation; RW.3 supports only schedule=N with N > 0. Run
             1 uses the root seed; later runs use successive SplitMix64
             outputs, skipping already accepted seeds.
  
  COMMON OPTIONS
         --help[=FMT] (default=auto)
             Show this help in format FMT. The value FMT must be one of auto,
             pager, groff or plain. With auto, the format is pager or plain
             whenever the TERM env var is dumb or undefined.
  
         --version
             Show version information.
  
  EXIT STATUS
         jacquard relate exits with:
  
         0   on success.
  
         123 on indiscriminate errors reported on standard error.
  
         124 on command line parsing errors.
  
         125 on unexpected internal errors (bugs).
  
  SEE ALSO
         jacquard(1)
  

The stable fixture enters a structured scope with one competing pure child,
awaits it, and then emits Console bytes from the parent. The bytes are observed
but never leak to success stdout; the redundancy warning is emitted once
across all eight constituents.

  $ cat > stable.jac <<'EOF'
  > worker() = {
  >   let child = async.spawn(fn () -> 7)
  >   let result = async.await(child)
  >   `op:print`("hidden")
  >   match True {
  >     | _ -> result
  >     | _ -> result
  >   }
  > }
  > 
  > async.scope(fn () -> worker())
  > EOF
  $ jacquard relate stable.jac --vary schedule=8 --seed 42 --allow console > stable.out 2> stable.err
  $ cat stable.out
  relate runs=8 seed=42 verdict=equal
  $ grep -c 'warning\[W0801\]' stable.err
  1
  $ cat stable.out stable.err | awk '/hidden/{count++} END{print count+0}'
  0

Console input is captured by ordinal during run 1 and replayed from a fresh
cursor in every later run. One physical input line therefore feeds all three
constituents instead of either later run consuming process EOF.

  $ echo '`op:read-line`()' > console-input.jac
  $ printf 'replayed\n' | jacquard relate console-input.jac --vary schedule=3 --seed 1 --allow console
  relate runs=3 seed=1 verdict=equal

Scheduler seeds never replace the fixed root seed used by Dist grants.

  $ echo '`op:sample`(Bernoulli(0.9))' > fixed-dist.jac
  $ jacquard relate fixed-dist.jac --vary schedule=4 --seed 42 --allow dist
  relate runs=4 seed=42 verdict=equal

Private-store acquisition failures remain structured store diagnostics instead
of escaping through the CLI's unexpected-internal-error boundary.

  $ touch not-a-directory
  $ TMPDIR="$PWD/not-a-directory" jacquard relate stable.jac --vary schedule=1 --seed 1 > bad-store.out 2>&1; exit_code=$?; grep 'error\[E0611\]' bad-store.out; echo $exit_code
  error[E0611]: Relational constituent store could not be prepared
  1

Every malformed, non-positive, or unsupported variation is a Cmdliner usage
error and names the only supported schedule=N form.

  $ jacquard relate stable.jac --vary nope --seed 1
  Usage: jacquard relate [--help] [OPTION]… FILE
  jacquard: option '--vary': expected schedule=N with N > 0
  [124]
  $ jacquard relate stable.jac --vary schedule=0 --seed 1
  Usage: jacquard relate [--help] [OPTION]… FILE
  jacquard: option '--vary': expected schedule=N with N > 0
  [124]
  $ jacquard relate stable.jac --vary secret=name --seed 1
  Usage: jacquard relate [--help] [OPTION]… FILE
  jacquard: option '--vary': expected schedule=N with N > 0
  [124]
  $ jacquard relate stable.jac --seed 1
  Usage: jacquard relate [--help] [OPTION]… FILE
  jacquard: required option --vary is missing
  [124]
  $ jacquard relate stable.jac --vary schedule=2
  Usage: jacquard relate [--help] [OPTION]… FILE
  jacquard: required option --seed is missing
  [124]
  $ jacquard relate --vary schedule=2 --seed 1
  Usage: jacquard relate [--help] [OPTION]… FILE
  jacquard: required argument FILE is missing
  [124]

Constituent failures keep the ordinary diagnostic, runtime, and authority
classes instead of becoming E1003.

  $ cat > malformed.jac <<'EOF'
  > not-valid(
  > EOF
  $ jacquard relate malformed.jac --vary schedule=2 --seed 1
  malformed.jac:2:1-1: error[E1220]: Surface syntax is invalid
    Cause: expected an expression, found eof
    Next step: Correct the syntax at this location and parse the file again.
  malformed.jac:2:1-1: error[E1220]: Surface syntax is invalid
    Cause: expected `,` or `)`, found eof
    Next step: Correct the syntax at this location and parse the file again.
  [1]
  $ echo 'div(1, 0)' > runtime.jac
  $ jacquard relate runtime.jac --vary schedule=2 --seed 1
  error: Arithmetic operation failed
    Cause: arithmetic error: division by zero
    Next step: Correct the arithmetic inputs and run the program again.
  [2]

Private constituent stores are removed after both successful and failed runs.

  $ mkdir cleanup-tmp
  $ TMPDIR="$PWD/cleanup-tmp" jacquard relate stable.jac --vary schedule=2 --seed 1 --allow console > /dev/null 2>&1
  $ TMPDIR="$PWD/cleanup-tmp" jacquard relate runtime.jac --vary schedule=2 --seed 1 > /dev/null 2>&1; test $? = 2
  $ find cleanup-tmp -mindepth 1 -print | wc -l
  0

Authority refusal remains status 3.

  $ echo '`op:print`("refused")' > refused.jac
  $ jacquard relate refused.jac --vary schedule=2 --seed 1
  error[E0814]: The program requires an effect that was not granted
    Cause: This program requires console [world/low] — talk to the process terminal, which is not granted (performed via `print`).
    Next step: grant it with --allow console, or handle the effect in the program
  [3]
