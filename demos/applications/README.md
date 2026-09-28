# Everyday applications as acceptance fixtures

Four small applications written against the public `.jac` surface during the
0.2 application journals are kept here as maintained fixtures for compiler and
library work: a push-your-luck dice coach, a picnic decision planner, a staff
rota optimizer, and a formula notebook. They use only synthetic data, need
only the `console` grant, and carry their own Warp suites, hand-calculated
results, and recorded transcripts. The originals live in the separate
application journals and are not edited here. These copies have been migrated
since import (see "Workarounds retired and kept"); `MANIFEST.sha256` records
their current bytes, which `sha256sum -c MANIFEST.sha256` verifies.
`scripts/applications/import.sh SOURCE_DIR` would restore the delivered
snapshot and rewrite the manifest.

## Layout

| directory | authored files | entry points |
|---|---|---|
| `shared/` | `display.jac` (three-decimal rendering), `display-tests.jac` | project `display`, used by the two applications below |
| `dice-coach/` | `model.jac`, `tests.jac` | `demo.jac`, `interactive.jac`, `EXAMPLE.txt` |
| `picnic-planner/` | `model.jac`, `tests.jac` | `demo.jac`, `interactive.jac`, `EXAMPLE.txt` |
| `rota-optimizer/` | `model.jac`, `fixtures.jac`, `report.jac`, `tests.jac`, `interaction-tests.jac`, `custom-example.jac` | `demo.jac`, `interactive.jac`, `EXAMPLE.txt`, `CUSTOM-EXAMPLE.txt` |
| `formula-notebook/` | `syntax.jac`, `model.jac`, `commands.jac`, `application.jac`, `workbook.jac`, `parser-tests.jac`, `model-tests.jac`, `interaction-tests.jac`, `smoke.jac` | `demo.jac`, `interactive.jac`, `EXAMPLE.txt` |
| `suite/` | `interaction-tests.jac` (dice and picnic interactive loops under a Console/State handler) | the shared interaction suite |

Each directory is a local project with a `project.jqd` manifest
(`docs/designs/project-structure.md`). The library units compose as one
program, and every declaration keeps exactly the identity it had when the
applications were assembled by concatenating their files. Each entry point
(`demo`, `interactive`, the Warp suites) is a manifest entry. `dice-coach` and
`picnic-planner` depend on `display`, which exports only the two helpers they
use (`display.percent`, `display.fixed3`); `suite` depends on all three.
`run.sh` is a thin wrapper over `jacquard project`:

```sh
demos/applications/run.sh dice-coach demo                 # the recorded transcript
demos/applications/run.sh picnic-planner interactive      # reads answers from stdin
demos/applications/run.sh rota-optimizer check            # the demo needs only Console
demos/applications/run.sh formula-notebook test           # its Warp suite (sampled properties)
JACQUARD_APPLICATIONS_EXHAUSTIVE=1 demos/applications/run.sh rota-optimizer test
demos/applications/run.sh dice-coach build ./dice-demo    # native binary of the demo
demos/applications/run.sh dice-coach build-interactive ./dice
```

The dice and picnic suites are one suite, run in the project that owns each
part: `display`'s tests, both models' suites, and the shared interaction
tests; `run.sh dice-coach test` and `run.sh picnic-planner test` run all four
and sum them. Suites run with `--seed 42 --no-cache`, as the applications
document. The same commands work directly, from any directory:

```sh
jacquard project run --project demos/applications/dice-coach demo --allow console
jacquard project test --project demos/applications/rota-optimizer --seed 42 --no-cache
jacquard project build --project demos/applications/formula-notebook demo -o ./notebook
```

Pins name each dependency's context identity, which covers the prelude and
the Core version. After a prelude or Core change, run `jacquard project pin`
in `dice-coach`, `picnic-planner` and `suite`.

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
- **Effect separation.** `project check --strict-grants` confirms each entry's
  declared `(grants console)` is exactly its checked authority; the models are
  pure or `Dist`-internal, and only presentation carries `Console`.
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

All eight entry points build with `jacquard project build` and match the interpreter:
the dice coach and picnic planner had never built natively before the
text-primitive and numeric-presentation repairs landed. What is not native:

- Warp suites (`jacquard test`) run under the interpreter only; there is no
  native test runner. Native evidence is the demo and interactive transcripts.

`smoke.jac`, `custom-example.jac`, `CUSTOM-EXAMPLE.txt`, and the shared
`display-tests.jac` are imported for completeness; the routine lane does not
run the first two separately.

## Workarounds retired and kept

The applications were imported byte-for-byte from their journals (the import
commit pins that snapshot) and have since been migrated to the language and
library features their findings asked for. Every migration below leaves each
`EXAMPLE.txt` and `CUSTOM-EXAMPLE.txt` byte-identical, keeps every suite
passing with the same checks (plus two display rounding pins), and keeps
interpreter and native output equal. The one behavior change is marked; the
notebook's end-of-input test now asserts that a blank line reprompts.

| workaround as delivered | now | where |
|---|---|---|
| split `$"..."` reports joined with `text.concat` (native v1's eight-argument call cap) | one interpolation per message | rota `report.jac` |
| nested `text.concat` chains | interpolation | notebook `commands.jac`, `syntax.jac`, `model-tests.jac`; shared `display.jac` |
| hand-written decimal parser with a digit table (native v1 lacked `text.to-int`) | `text.to-int` of the trimmed line; the six-digit input bound stays | rota `report.jac` |
| `text.to-real(text.from-int(n))` Int-to-Real helpers (`dice.real`, `picnic.real`, `display.real`) | `real.from-int` | dice, picnic, shared |
| digit and letter tables (`nb.digits`, `nb.letters`) | `text.ascii-digit?`, `text.ascii-digit-value`, `text.ascii-letter?` | notebook `syntax.jac` |
| `text.eq?` chains over characters and command words | Text patterns in `match` | notebook `syntax.jac`, `commands.jac` |
| recursive `rota.every`/`rota.any`, `nb.every`/`nb.any` | `list.all?`, `list.any?` | rota, notebook |
| `bool.and(int.gte?(x, lo), int.lte?(x, hi))` ranges | `int.between?`, `real.between?` (negated with `bool.not` for out-of-range errors) | dice, picnic, rota, notebook |
| nested `bool.and` conjunctions | `bool.all([...])` | picnic `model.jac`; rota input validation and solution check |
| 29 hand-written field selectors (`rota.staff-id`, `nb.cells`, ...) | generated accessors (`rota-staff.id`, `nb-snapshot.cells`, `nb-response.output`, ...) | rota, notebook |
| one-clause `match` projections (`NbEdge(source: s) -> s`) | generated accessors (`nb-edge.source`, `nb-entry.name`) | notebook |
| rebuilding a whole record to change one or two fields | generated setters (`rota-staff.with-available`, `nb-snapshot.with-hits`, `with-cache`, `with-computed`) | rota `fixtures.jac`, notebook `model.jac` |
| an empty line ended the notebook, because `read-line` answers `""` at end of input | `next-line()`: a blank line now reprompts; `quit` or end of input ends the session (**UX change**, prints `bye (end of input)`) | notebook `application.jac` |
| programs assembled by concatenating files | local projects (`project.jqd`) | all |

Kept on purpose:

- `display.fixed3` stays hand-written. It rounds half up on the scaled float,
  which is what the recorded transcripts print; `text.from-real-fixed` rounds
  the exact binary value and would print the picnic park's `80.643` as
  `80.642`. `display-tests.jac` pins the difference.
- Domain bounds and validation: the rota's six-digit prompt bound, shift and
  staff ranges and 20000-node budget; the notebook's 24-character names,
  100-token formulas, 1000000 literal bound, 8192-character commands and
  twenty-edit history.
- `rota.member?`, `rota.distinct?`, `nb.has` and `nb.unique` compare with
  `eq`/`text.eq?` directly; `list.contains?` needs an `Eq` dictionary and
  reads no better here.
- Dice, picnic and rota read their prompts with `console.ask`, where end of
  input arrives as an empty answer and is reported as invalid input; only the
  notebook, whose loop needs to tell a blank line from the end, uses
  `next-line()`.
- The rota's preference entries are prelude `Pair`s, which have no generated
  accessors, so their `MkPair(key, _)` matches stay.
- The independent oracles and the notebook's fresh-evaluator comparison are
  unchanged, and the record rebuilds that replace three or more fields keep
  the constructor call.
