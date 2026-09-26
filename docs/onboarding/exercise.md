# Documentation-Only Onboarding Exercise

A small formative exercise: can a developer who has never worked on Jacquard
set it up, run a real application, change it, diagnose an error, and build
it natively, using only the public documentation? It is not a readability
study, a benchmark, or a release gate.

The application is the staff rota optimizer in
`demos/applications/rota-optimizer`. It is a local project (`project.jqd`),
so every step uses `jacquard project`. The transcript
`test/cli/onboarding.t` runs each scripted step in CI, so the expected
outcomes below stay true.

## Who takes part

- **Participant:** a developer comfortable with a terminal and one typed
  functional or ML-family language, who has not worked on Jacquard and has
  not read its source. They may read the checkout's `README.md`, anything
  under `docs/`, the demo guides the README's documentation map points to
  (`demos/README.md` and `demos/applications/README.md`), and the
  application's own files.
- **Facilitator:** watches, times each task, and records interventions. They
  do not explain the language or the tools.
- **Owner read-through:** the maintainer reads this protocol and the
  documentation it relies on, and records feedback in the same sheet under
  "owner review". That is useful evidence about the documents. It is **not**
  participant evidence, and the exercise stays open until an unfamiliar
  developer has done it.

Do not contact a participant without the maintainer's authorization. Record no
names, email addresses or other identifying details; use `P1`, `P2`, and so
on.

## Rules for the facilitator

1. Hand over this file's **Participant instructions** section and nothing else.
2. Do not answer questions about the language, the tools or the diagnostics.
   If the participant has been stuck for ten minutes, offer the task's
   **hint** (below), and record it as an intervention.
3. If the participant is still stuck five minutes after the hint, offer the
   **answer**, record it, and move to the next task.
4. Record the time each task starts and ends, whether it succeeded without
   intervention, with the hint, or with the answer, and every point of
   friction the participant mentions or visibly hits.
5. Never substitute a run by another informed person or an agent for the
   participant's attempt.

## Participant instructions

You will set up a development checkout of Jacquard, then run, change, repair
and compile a small application. Use only the repository's documentation
(`README.md`, `docs/`, `demos/README.md`, `demos/applications/README.md`) and
the application's files. Say what you are looking
for and what you expect as you go.

**Task 1. Set up.** From a fresh clone, follow the README's *Development Quick
Start* until `dune build @all` succeeds. Then make the `jacquard` command
available in your shell (the README's *Running Jacquard* section shows how to
run the built binary).

*Done when:* `jacquard --version` prints a version.

**Task 2. Run the application.** The rota optimizer lives in
`demos/applications/rota-optimizer`. Run its `demo` entry with the console
grant it needs, from any directory.

*Done when:* the output matches that directory's `EXAMPLE.txt`, whose first
line is `STAFF ROTA OPTIMIZER` and which reports `PROVEN OPTIMAL` with score
73.

**Task 3. Run its tests.** Run the project's Warp suite with seed `42` and no
result cache.

*Done when:* the summary line reads `17 passed, 0 failed, 0 skipped, 0 refused`.

**Task 4. Change the model.** Evening shifts currently start at 16:00. Make
them start at 15:00, then run the demo again.

*Done when:* the first evening shift is listed as `Mon PM [hours 15..23, lead]`.
Keep your change for Task 6.

**Task 5. Diagnose an error.** Apply the seeded error: in the project's
`fixtures.jac`, replace `rota.day-name(day)` with `day` in the shift label.
Run the project's check, find what is wrong from the diagnostic alone,
and repair it.

*Done when:* `jacquard project check` for the project reports the library and
every entry as checked.

**Task 6. Build natively.** Compile the `demo` entry to a standalone binary
and run it.

*Done when:* the binary prints the same transcript as your Task 4 run.

**Task 7. Debrief.** In two or three sentences each: What was hardest? What
did you expect the documentation to tell you that it did not? What would you
try next?

## Hints and answers (facilitator only)

| task | hint | answer |
|---|---|---|
| 1 | The README's *Running Jacquard* section runs the built binary through Dune. | `eval "$(opam env)"`, then `alias jacquard='opam exec -- dune exec jac --'`. |
| 2 | The project commands take `--project DIR`; the demo prints to the console. | `jacquard project run --project demos/applications/rota-optimizer demo --allow console` |
| 3 | `jacquard project test` takes Warp's flags. | `jacquard project test --project demos/applications/rota-optimizer --seed 42 --no-cache` |
| 4 | Shift start times are computed in `fixtures.jac`. | In `rota.week-shifts`, change `if evening then 16 else 8` to `if evening then 15 else 8`. |
| 5 | The diagnostic names the file, line and the two types that disagree. | The label concatenates text; `day` is an `Int`. Restore `rota.day-name(day)`. |
| 6 | Only entries marked `(native)` in `project.jqd` build. | `jacquard project build --project demos/applications/rota-optimizer demo -o rota && ./rota --allow console` |

## Recording sheet

Copy this table for each participant, and once more for the owner review.

| task | start | end | outcome (unaided / hint / answer / not reached) | friction observed |
|---|---|---|---|---|
| 1 set up | | | | |
| 2 run | | | | |
| 3 tests | | | | |
| 4 change | | | | |
| 5 diagnose | | | | |
| 6 native | | | | |
| 7 debrief | | | | |

Keep completed sheets outside the repository unless they contain no
identifying details. File follow-up tasks only for friction that more than
one source (participant, owner review, or a repeat) shows, and label every
finding with its source. Do not mix these results with the project's
development-time estimates.
