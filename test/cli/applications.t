The four everyday applications (dice coach, picnic planner, rota optimizer,
formula notebook) are maintained under demos/applications as acceptance
fixtures for compiler and library work. Their sources are synthetic, their
provenance is a SHA-256 manifest, and the launcher assembles each entry point
the way the applications' own instructions do. This routine lane pins the
baseline: every demo transcript equals the recorded EXAMPLE.txt under the
interpreter and natively, real interactive sessions agree between engines, the
demo manifests need only Console, and each Warp suite passes with sampled
properties. The exhaustive property lane is `dune build @applications-exhaustive`.

  $ export JACQUARD_PRELUDE=$PWD/../../prelude
  $ export TMPDIR=$PWD/.scratch/tmp
  $ mkdir -p "$TMPDIR" native
  $ A=../../demos/applications
  $ (cd "$A" && sha256sum -c MANIFEST.sha256 | grep -vc ': OK$')
  0
  [1]

  $ for app in dice-coach picnic-planner rota-optimizer formula-notebook; do
  >   JACQUARD=jac sh "$A/run.sh" $app check > /dev/null && echo "manifest ok: $app"
  > done
  manifest ok: dice-coach
  manifest ok: picnic-planner
  manifest ok: rota-optimizer
  manifest ok: formula-notebook

The recorded demo transcripts (the hand-checked picnic scores 51.855 / 64.520 /
53.930, the dice optimal policy at pot 19, the proven-optimal rota score 73 in
705 nodes, and the notebook's 1200 -> 1500 what-if) are reproduced exactly by
both engines:

  $ for app in dice-coach picnic-planner rota-optimizer formula-notebook; do
  >   JACQUARD=jac sh "$A/run.sh" $app demo > "$app-demo.out" 2>&1; interpreter_status=$?
  >   JACQUARD=jac sh "$A/run.sh" $app build "$PWD/native/$app" > /dev/null 2>&1; build_status=$?
  >   "./native/$app" --allow console > "$app-demo.native" 2>&1; native_status=$?
  >   cmp "$app-demo.out" "$A/$app/EXAMPLE.txt" && cmp "$app-demo.native" "$A/$app/EXAMPLE.txt" \
  >     && test "$interpreter_status$build_status$native_status" = 000 && echo "demo transcript: $app"
  > done
  demo transcript: dice-coach
  demo transcript: picnic-planner
  demo transcript: rota-optimizer
  demo transcript: formula-notebook
  $ grep -c 'enjoyment = 51.855\|enjoyment = 64.520\|enjoyment = 53.930' "$A/picnic-planner/EXAMPLE.txt"
  6
  $ grep -c 'PROVEN OPTIMAL' "$A/rota-optimizer/EXAMPLE.txt"
  3

Real interactive sessions over standard input: a valid dice and picnic
scenario, a rota input error, and a notebook edit followed by end of input.
Each session prints byte-identically under the interpreter and the native
binary:

  $ printf '19\n3\n' > dice-coach.in
  $ printf '30\n80\n1\n' > picnic-planner.in
  $ printf '1\n-1\n0\n0\n0\n' > rota-optimizer.in
  $ printf 'set a = 1\nset b = a + 1\nshow b\n\n' > formula-notebook.in
  $ for app in dice-coach picnic-planner rota-optimizer formula-notebook; do
  >   JACQUARD=jac sh "$A/run.sh" $app interactive < "$app.in" > "$app-i.out" 2>&1; interpreter_status=$?
  >   JACQUARD=jac sh "$A/run.sh" $app build-interactive "$PWD/native/$app-interactive" > /dev/null 2>&1
  >   "./native/$app-interactive" --allow console < "$app.in" > "$app-n.out" 2>&1; native_status=$?
  >   cmp "$app-i.out" "$app-n.out" && test "$interpreter_status" = "$native_status" \
  >     && echo "interactive parity: $app (exit $native_status)"
  > done
  interactive parity: dice-coach (exit 0)
  interactive parity: picnic-planner (exit 0)
  interactive parity: rota-optimizer (exit 0)
  interactive parity: formula-notebook (exit 0)
  $ grep 'optimal expected score' -A1 dice-coach-i.out | tail -1
      expected banked points = 19.167; bust probability = 16.667%
  $ grep 'worth' picnic-planner-i.out
  Forecast information is worth 3.275 enjoyment points before its cost.
  $ grep 'INPUT ERROR' rota-optimizer-i.out
  INPUT ERROR: Node budget must be 0..20000.
  $ grep 'b = 2\|bye' formula-notebook-i.out
  b = 2    [a + 1]
  bye (empty input or EOF)

The Warp suites with sampled properties (the exhaustive lane reruns them with
`--exhaustive`): the shared dice/picnic suite, the rota suite with its naive
exhaustive oracle and budget-monotonicity properties, and the notebook suite
with its fresh-evaluator comparisons and cache/history invariants.

  $ JACQUARD=jac sh "$A/run.sh" dice-coach test 2>&1 | tail -1
  25 passed, 0 failed, 0 skipped, 0 refused
  $ JACQUARD=jac sh "$A/run.sh" rota-optimizer test 2>&1 | tail -1
  17 passed, 0 failed, 0 skipped, 0 refused
  $ JACQUARD=jac sh "$A/run.sh" formula-notebook test 2>&1 | tail -1
  18 passed, 0 failed, 0 skipped, 0 refused
