# Everyday applications as acceptance fixtures

Four small applications written against the public `.jac` surface during the
0.2 application journals are kept here as maintained fixtures for compiler and
library work: a push-your-luck dice coach, a picnic decision planner, a staff
rota optimizer, and a formula notebook. They use only synthetic data, need
only the `console` grant, and carry their own Warp suites, hand-calculated
results, and recorded transcripts. The originals live in the separate
application journals and are not edited here; `scripts/applications/import.sh
SOURCE_DIR` refreshes these copies and rewrites `MANIFEST.sha256`, which
`sha256sum -c MANIFEST.sha256` verifies. Every file here has the same bytes
as the recorded application snapshot it was imported from.

## Layout

| directory | authored files | entry points |
|---|---|---|
| `shared/` | `display.jac` (three-decimal rendering), `display-tests.jac`, `interaction-tests.jac` (dice and picnic interactive loops under a Console/State handler) | used by the two applications below |
| `dice-coach/` | `model.jac`, `tests.jac` | `demo.jac`, `interactive.jac`, `EXAMPLE.txt` |
| `picnic-planner/` | `model.jac`, `tests.jac` | `demo.jac`, `interactive.jac`, `EXAMPLE.txt` |
| `rota-optimizer/` | `model.jac`, `fixtures.jac`, `report.jac`, `tests.jac`, `interaction-tests.jac`, `custom-example.jac` | `demo.jac`, `interactive.jac`, `EXAMPLE.txt`, `CUSTOM-EXAMPLE.txt` |
| `formula-notebook/` | `syntax.jac`, `model.jac`, `commands.jac`, `application.jac`, `workbook.jac`, `parser-tests.jac`, `model-tests.jac`, `interaction-tests.jac`, `smoke.jac` | `demo.jac`, `interactive.jac`, `EXAMPLE.txt` |

`run.sh` assembles each entry point exactly as the applications' own
instructions do, by concatenating the authored files into one source under
`$TMPDIR`; the assembled file is removed on exit. Retiring that concatenation
in favour of the store workflow is later work (the fixtures record the
baseline first).

```sh
demos/applications/run.sh dice-coach demo                 # the recorded transcript
demos/applications/run.sh picnic-planner interactive      # reads answers from stdin
demos/applications/run.sh rota-optimizer check            # the demo needs only Console
demos/applications/run.sh formula-notebook test           # its Warp suite (sampled properties)
JACQUARD_APPLICATIONS_EXHAUSTIVE=1 demos/applications/run.sh rota-optimizer test
demos/applications/run.sh dice-coach build ./dice-demo    # native binary of the demo
demos/applications/run.sh dice-coach build-interactive ./dice
```

The dice and picnic suites are one suite (the shared display and interaction
tests exercise both models); `run.sh dice-coach test` and `run.sh
picnic-planner test` run the same files. Suites run with `--seed 42
--no-cache`, as the applications document.

## What the baseline pins

- **Demo transcripts.** `EXAMPLE.txt` is the recorded output of each demo and
  is reproduced byte-for-byte by the interpreter and by the native binary. It
  carries the hand-calculated results: the picnic expected enjoyments 51.855
  (park), 64.520 (pavilion), 53.930 (indoors) and the 3.275-point value of an
  80%-accurate forecast; the dice policy at pot 19 with three rolls (optimal
  19.167 expected points at 16.667% bust); the rota week proven optimal at
  score 73 (125 preference minus 52 penalty) in 705 nodes; the notebook's
  1200 to 1500 what-if.
- **Independent oracles.** The dice one-roll closed form `(5 * pot + 20) / 6`
  and a three-roll survival calculation; the rota naive exhaustive oracle,
  partial-bound versus exhaustive completions, and budget monotonicity; the
  notebook's fresh-evaluator comparisons after every generated transition.
- **Effect separation.** Each demo passes `check --manifest console`; the
  models are pure or `Dist`-internal, and only presentation carries `Console`.
- **History and cache invariants.** The notebook suite checks that a diamond
  dependency computes once per affected cell, stale edges are removed,
  abandoned errors are evicted, history is capped at twenty edits, redo is
  cleared by a branch, and previews do not mutate.
- **Real interaction.** The routine lane feeds real standard input to every
  `interactive` entry point (a valid dice and picnic scenario, a rota input
  error, a notebook edit followed by end of input) and requires the
  interpreter and the native binary to print identically.

## Lanes

- Routine: `test/cli/applications.t`, part of `dune runtest`. Provenance,
  manifests, demo transcripts under both engines, interactive parity, and the
  three suites with sampled properties.
- Exhaustive: `dune build @applications-exhaustive` (workflow
  `.github/workflows/applications.yml`, path-scoped, not a required check).
  Every suite with `--exhaustive` (327 dice/picnic cases over seven
  properties, the rota oracle and budget properties, the notebook's 1024
  fresh-evaluator comparisons), then native parity of every demo.

## Native coverage and gaps

All eight entry points build with `jacquard build` and match the interpreter:
the dice coach and picnic planner had never built natively before the
text-primitive and numeric-presentation repairs landed. What is not native:

- Warp suites (`jacquard test`) run under the interpreter only; there is no
  native test runner. Native evidence is the demo and interactive transcripts.
- The applications still carry their own workarounds (a hand-written decimal
  parser, display helpers that the library now provides, the notebook's
  empty-line handling of end of input, source concatenation). They are kept
  as recorded so the baseline is the applications as delivered; migrating
  them is separate work that will move fixtures one repair at a time.

`smoke.jac`, `custom-example.jac`, `CUSTOM-EXAMPLE.txt`, and the shared
`display-tests.jac` are imported for completeness; the routine lane does not
run the first two separately.
