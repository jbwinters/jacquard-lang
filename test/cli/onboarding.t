The documentation-only onboarding exercise (docs/onboarding/exercise.md) is
kept executable: every scripted step, with the outcome the exercise promises.
The participant's route is the documentation; this transcript only guards the
expected results.

  $ export JACQUARD_PRELUDE=$PWD/../../prelude
  $ export JACQUARD_RUNTIME=$PWD/../../runtime
  $ mkdir demos && cp -RL ../../demos/applications ../../demos/lib demos/ && chmod -R u+w demos
  $ P=$PWD/demos/applications/rota-optimizer

Task 2, from an unrelated directory:

  $ (cd /tmp && jacquard project run --project "$P" demo --allow console) > demo.out
  $ cmp demo.out "$P/EXAMPLE.txt" && head -1 demo.out && grep -c 'PROVEN OPTIMAL' demo.out
  STAFF ROTA OPTIMIZER
  3

Task 3:

  $ jacquard project test --project "$P" --seed 42 --no-cache | tail -1
  17 passed, 0 failed, 0 skipped, 0 refused

Task 4:

  $ grep -c 'if evening then 16 else 8' "$P/fixtures.jac"
  1
  $ sed -i 's/if evening then 16 else 8/if evening then 15 else 8/' "$P/fixtures.jac"
  $ jacquard project run --project "$P" demo --allow console > changed.out
  $ grep -o 'Mon PM \[hours 15..23, lead\]' changed.out
  Mon PM [hours 15..23, lead]

Task 5, the seeded error and what its diagnostic says:

  $ cp "$P/fixtures.jac" fixtures.good
  $ sed -i 's/text.concat(rota.day-name(day), /text.concat(day, /' "$P/fixtures.jac"
  $ jacquard project check --project "$P" 2>&1 | grep -o 'fixtures.jac:[0-9]*:[0-9-]*: error\[E0801\].*\|Cause: .*' | head -2
  fixtures.jac:26:30-33: error[E0801]: Types do not agree
  Cause: argument: expected text, got int (type mismatch)
  $ cp fixtures.good "$P/fixtures.jac"
  $ jacquard project check --project "$P" | tail -4
  entry demo (run): checked; requires console
  entry interactive (run): checked; requires console
  entry custom-example (run): checked; requires console
  entry suite (test): checked, 3 tests; requires nothing

Task 6:

  $ jacquard project build --project "$P" demo -o rota > /dev/null 2>&1 && ./rota --allow console > native.out
  $ cmp native.out changed.out && echo same
  same
