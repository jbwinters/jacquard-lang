The four everyday applications (dice coach, picnic planner, rota optimizer,
formula notebook) are maintained under demos/applications as acceptance
fixtures for compiler and library work. Their sources are synthetic, their
provenance is a SHA-256 manifest, and each is a local project (project.jqd)
that the launcher drives through `jacquard project`. They run from a
dereferenced copy, since a project's units must resolve inside its directory.
This routine lane pins the baseline: every demo transcript equals the recorded EXAMPLE.txt under the
interpreter and natively, real interactive sessions agree between engines, the
demo manifests need only Console, and each Warp suite passes with sampled
properties. The exhaustive property lane is `dune build @applications-exhaustive`.

  $ export JACQUARD_PRELUDE=$PWD/../../prelude
  $ export TMPDIR=$PWD/.scratch/tmp
  $ mkdir -p "$TMPDIR" native
  $ mkdir demos && cp -RL ../../demos/applications ../../demos/lib demos/ && chmod -R u+w demos
  $ A=$PWD/demos/applications
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
  bye (end of input)

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

The applications read and update their records through the generated D36 field
accessors and setters (SX.27, SX.28), such as `rota-staff.id`, `nb-snapshot.cells`,
and `rota-staff.with-available`, and the notebook's multi-field rebuilds are
`with` field updates (SX.28b). None of the hand-written selectors they were
delivered with remain:

  $ grep -rhoE --include='*.jac' '\b(rota\.(staff-id|staff-name|staff-limit|shift-id|shift-label|people|shifts|rest|weight|solution-score|solution-assignments)|nb\.(response-book|response-output|response-stop\?|cell-name|cell-source|cell-expr|cell-deps|cells|edges|cache|hits|computed|current|undo-list|redo-list|outcome-book|outcome-message|accepted\?))\(' "$A" | wc -l
  0
  $ grep -rhoE --include='*.jac' '\b(rota-staff|nb-snapshot)\.with-[a-z]+' "$A" | sort | uniq -c
        1 nb-snapshot.with-hits
        1 rota-staff.with-available
  $ grep -rhoE --include='*.jac' '\b[A-Z][A-Za-z]*\([a-z-]+ with\b' "$A" | sort | uniq -c
        1 NbSnapshot(next with
        1 NbSnapshot(snapshot with

Project composition preserves every identity: each entry's bindings, with its
dependencies', hash exactly as the concatenation the applications used to be
assembled from:

  $ same() { # project entry files...
  >   p=$1; e=$2; shift 2; cat "$@" > assembled.jac
  >   jac hash assembled.jac | grep ':' | sed 's/^[0-9]*://' | sort -u > concatenated.txt
  >   { jac project hash --project "$A/$p" $e; [ -f "$A/$p/model.jac" ] && [ "$p" != rota-optimizer ] \
  >       && [ "$p" != formula-notebook ] && jac project hash --project "$A/shared"; } \
  >     | cut -d' ' -f2- | sort -u > composed.txt
  >   cmp -s concatenated.txt composed.txt && echo "identical: $p $e ($(wc -l < composed.txt) bindings)"; }
  $ same dice-coach demo "$A/shared/display.jac" "$A/dice-coach/model.jac" "$A/dice-coach/demo.jac"
  identical: dice-coach demo (31 bindings)
  $ same picnic-planner suite "$A/shared/display.jac" "$A/picnic-planner/model.jac" "$A/picnic-planner/tests.jac"
  identical: picnic-planner suite (49 bindings)
  $ R="$A/rota-optimizer"; same rota-optimizer suite "$R/model.jac" "$R/fixtures.jac" "$R/report.jac" "$R/tests.jac" "$R/interaction-tests.jac"
  identical: rota-optimizer suite (128 bindings)
  $ N="$A/formula-notebook"; same formula-notebook demo "$N/syntax.jac" "$N/model.jac" "$N/commands.jac" "$N/application.jac" "$N/workbook.jac" "$N/demo.jac"
  identical: formula-notebook demo (172 bindings)

The display helpers the applications do not use stay private to `display`:
by name, by hash, and through eval:

  $ cp "$A/dice-coach/demo.jac" demo.bak
  $ echo 'display.floor-between(1.5, 0, 2)' > "$A/dice-coach/demo.jac"
  $ jac project run --project "$A/dice-coach" demo 2>&1 | grep -o 'error\[E1705\].*' | head -1
  error[E1705]: A name is not visible in this project.
  $ H=$(jac project hash --project "$A/shared" | grep ' display.floor-between ' | cut -d' ' -f3)
  $ printf '#%s:term(1, 2, 3)\n' "$H" > "$A/dice-coach/demo.jac"
  $ jac project run --project "$A/dice-coach" demo 2>&1 | grep -o 'error\[E1709\]' | head -1
  error[E1709]
  $ echo '`op:eval-code`(quote { display.floor-between(1.5, 0, 2) })' > "$A/dice-coach/demo.jac"
  $ jac project run --project "$A/dice-coach" demo --allow eval 2>&1 | grep -o 'E1705' | head -1
  E1705
  $ cp demo.bak "$A/dice-coach/demo.jac"

Nothing is assembled with cat any more:

  $ grep -c '\bcat\b' "$A/run.sh" "$A/README.md" | cut -d: -f2
  0
  0
