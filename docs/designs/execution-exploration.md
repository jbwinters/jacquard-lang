# DES.0 Interactive Execution Exploration

- Status: design proposal with a follow-up backlog. This document neither
  implements the feature nor approves any of it as a language or runtime
  contract.
- Date: 2026-09-24
- Base: `main` after these changes:
  - API.1: interface manifests and sealed checked identities.
  - Scoped effect instances (TS.1).
  - Typed inference outcomes, INF.1. This is PR #134 and has not merged yet.
    §4.6 depends on it.
- The owner decisions required before dependent implementation are listed in §10.

## 1. Question

A developer is looking at one decision their program made and wants to know:

1. What did it decide, and from which observations and random choices?
2. What would it have decided if one of those had been different?
3. How do the two executions differ, in their values and in the operations they
   would have performed?
4. How can the answer become a regression test that anyone can rerun?

Jacquard already contains every mechanism this needs, but they are separate
tools with separate vocabularies:

- recorded worlds and strict replay
- positional counterfactual replay
- dreamed worlds sampled from a model
- relational Warp's observation equality
- Warp's choice logs

This design proposes one source-linked workflow over them. It keeps the 27-form
kernel, `.jqd`, `HASH_V0`, and every released identity unchanged. Nothing real
is ever undone or re-executed.

## 2. Inventory Of Shipped Mechanisms

| mechanism | where | what it gives | what it lacks for this workflow |
|---|---|---|---|
| strict and loose replay, `net.record` | `prelude/17-codec.jqd` (W6.6) | a world log as one `Code` payload of `(op "name" ARGS RESULT)` triples, content-addressed. Strict replay fails on the first divergence and reports the differ's smallest disagreeing subtrees | covers only the `net` effect. No source positions and no random choices |
| `jacquard replay LOG PROGRAM --to N --fork N=FORM --compare` | `bin/main.ml` (TL.3) | serves `fetch` results positionally, scrubs to step N, and overrides step N with a form. After the log it runs under the dry handlers | covers `fetch` only. Forks are addressed by position and are untyped. Unmodeled operations silently get a stub, and the report is ad hoc text |
| dreamed worlds, `net.dream` | `demos/worlds/agent-dream.jac` | the same policy under scripted, hostile, dry and sampled worlds | a demo, not a tool. Worlds are chosen by editing source |
| relational lanes, `run-transcript-v1` | `docs/relational-warp.md` | a strict, length-framed observation encoding and first-divergence rendering. Variation of `secret`, `schedule` and `grant` | compares whole runs under a named variation, not a selected observation |
| choice logs and shrinking | `docs/warp-testing.md` §4 | a log of (distribution, outcome) per sample site, replayed with the logged choices forced | positional. Internal to the property driver and never shown to users |
| exact enumeration with a budget, typed outcomes | `dist.enumerate-v1` (INF.1) | posterior versus impossible, exhausted or numerical failure, plus completeness metadata | not connected to a selected choice |
| checked identities | `interface-v1`, `Frontend.Checked` (API.1, RF.1) | the program identity a saved scenario can bind to | — |
| source spans | kernel `Meta.span` | exact source positions at check time | not carried into runtime traces. `run-transcript-v1` names operations by hash only |

## 3. Walkthrough: The Delivery Planner

The walkthrough uses a proposed example. No delivery planner exists in the
repository today; follow-up EXP.7 adds it as a demo.

```jacquard
-- proposed example; `dist.named` is proposed in §4.2
type Plan = | Van | Bike | Hold

plan-delivery(order) = {
  let forecast = `op:fetch`(MkRequest("http://weather/today", ""))
  let traffic = dist.named("traffic", Categorical([MkPair("clear", 0.6), MkPair("jam", 0.4)]))
  match weather.rain?(forecast) {
    | True -> match eq-text(traffic, "jam") { | True -> Hold | False -> Van }
    | False -> match order.small?(order) { | True -> Bike | False -> Van }
  }
}
```

1. **Record.** `jacquard explore record planner.jac --entry plan-delivery
   --arg order.json --world recorded --seed 7 -o run.explore`.
   - The live `fetch` result and the sampled traffic outcome are written to an
     `exploration-log-v1` (§4.1).
   - The command prints the decision `Hold` and the two inputs it depended on.
     Each is listed with its source position, e.g. `planner.jac:5:18
     fetch → Response(200, "rain")` and `planner.jac:6:17 traffic → "jam"`.
2. **Inspect.** `jacquard explore show run.explore` lists every recorded step
   with the following details:
   - step number, operation name, choice name
   - the typed value
   - source position
   - whether a fork is allowed there (§4.3)
3. **Fork.** `jacquard explore fork run.explore --choice traffic=clear` reruns
   the checked program against the same recording.
   - `traffic` is overridden with `"clear"`, an outcome in the declared support.
   - Every other recorded step is served from the log.
   - The decision becomes `Van`.
4. **Compare.** The fork prints a side-by-side report (§4.5):
   - both decisions
   - the first divergence (the `match` on `traffic` at `planner.jac:7:22`)
   - the operations each execution performed or would have performed
   - a statement that the alternative ran under the recording, not live
5. **Explore a whole choice.** `jacquard explore enumerate run.explore
   --choice traffic` runs the fork for every outcome in the support. It reports
   the decision per outcome with the distribution's weights, using the INF.1
   typed outcome, e.g. `clear (0.6) → Van, jam (0.4) → Hold, complete`.
6. **Export.** `jacquard explore export run.explore --choice traffic=clear -o
   planner-clear.jac` writes a Warp `Test` (§4.6).
   - The test pins the checked program, the recorded world (by hash) and the
     override, and asserts the observed decision `Van`.
   - `jacquard test planner-clear.jac` reruns it hermetically, with no network.

A reviewer reading the exported test sees the program identity, the world
fixture and the single changed input. They do not need to have used the
explorer.

## 4. Proposal

### 4.1 Recording: `exploration-log-v1`

Recording is opt-in. `jacquard explore record` (or `run --record FILE`)
installs a recording layer outside the granted world handlers. It appends one
entry per root-reaching operation:

```text
(exploration-log-v1
  (program <checked-artifact-hash>) (entry <term-hash>) (seed <int>)
  (world <handler-identity>...)
  (step 1 (op <op-hash> "fetch") (at "planner.jac" 5 18)
          (args <code>) (result <code>))
  (step 2 (choice "traffic" 1) (at "planner.jac" 6 17)
          (dist <code>) (outcome <code>))
  (result <code>))
```

- It generalizes `net.record` from `net` to every world effect with a codec (D13
  already requires codecs for ring 3 world effects), and to Dist choices.
- Positions come from kernel `Meta.span` at the perform site. The evaluator
  must carry the span of an operation's perform node into the trace. This is
  EXP.1's runtime change; values and hashes are unaffected because spans are
  metadata.
- **Exposure.**
  - A `Secret` payload is never recorded: the entry records the operation and a
    redaction marker, and a fork of that step is refused.
  - Console output is recorded only when `--record-output` is given.
  - The log is written with owner-only file permissions.
  - The header of `explore show` states what was recorded.
- **Limits.** The recording refuses to grow past `--max-steps` (default
  10,000) or `--max-bytes` (default 16 MiB). It stops with a diagnostic
  rather than truncating silently.

### 4.2 Named random choices

Positional choice addressing breaks as soon as control flow changes. Warp's
shrinker already has to detect and skip the resulting misalignments. The
explorer instead addresses a choice by a name the author gives:

```text
dist.named : (Text, Distribution a) ->{Dist} a
```

- The proposal is a prelude function performing `sample`. It changes no
  released identity.
- Under the recording and fork handlers it contributes the name to the trace;
  under every other handler it is exactly `sample`.
- The address is `(name, k)` for the k-th draw under that name, so a named
  choice inside a loop is still addressable.
- Unnamed `sample` sites remain explorable by position (`--step N`). The report
  marks those forks as position-addressed, since a different path can shift
  the position.

The name is a debugging handle, not an identity. Renaming it changes the term's
hash as any literal would.

### 4.3 Legal fork points

A fork replaces exactly one recorded step, or one step per `--fork` flag, and
reruns the checked program from the beginning against the recording. There is
no in-place continuation surgery: replaying from the start keeps once
resumptions, handlers and scheduler state valid by construction.

| step | allowed override | refused |
|---|---|---|
| a world operation's result | a value of the operation's declared result type, checked before the run (a type diagnostic) | a value of another type; a step whose result carries a `Secret` or a capability (`Task`, `ChannelHandle`, a scoped instance) |
| a named or positional Dist choice | an outcome in the recorded distribution's support. An outcome outside the support needs `--outside-support`, and the report marks the fork impossible under the model | a non-member without the flag |
| an `observe` | nothing. Observations condition a model; changing one is a model edit, not a fork | always |
| a scheduler decision | deferred to the schedule-trace tools (`--schedule-record`, relational `schedule`) | in v1 |

After the fork, the replay layer compares each later world operation's name and
arguments with the next unconsumed log entry:

- It serves the recorded result when they match.
- When they do not match, it consults the modeled world named by `--world`
  (scripted, dry or dreamed).
- An operation with no model **stops** the alternative with the status
  `unmodeled`. It does not serve a stub, as TL.3 does today.

Live handlers are never installed during a fork. The type of `explore fork`'s
world argument excludes the root grant set, so running a fork cannot reach the
network, the filesystem, or a clock beyond what the recording and the models
supply.

### 4.4 Finite exploration

Every exploration command has explicit bounds:

- `--max-steps` per execution (evaluator fuel expressed in root-reaching
  operations)
- `--max-forks` per session (default 64)
- `explore enumerate` uses `dist.enumerate-v1`'s terminal-path budget
  (`--max-branches`) and reports its typed outcome: complete, exhausted,
  impossible or numerical failure.

A sampled exploration (`--samples N --seed S`) is labeled sampled and never
complete.

### 4.5 Comparison: `exploration-report-v1`

The report is data first. The text rendering and the Host presentation are both
views of it:

```text
(exploration-report-v1
  (scenario <scenario-hash>)
  (original (result <code>) (status complete) (steps ...))
  (alternative (fork (choice "traffic" 1) (outcome "clear"))
               (result <code>) (status complete|unmodeled|exhausted|failed <diag>)
               (steps ...))
  (first-divergence (step 2) (at "planner.jac" 7 22))
  (effects (only-original ...) (only-alternative ...) (both ...))
  (claims explanation-only))
```

- Values are compared with `run-transcript-v1` value encoding, reusing
  relational Warp's equality.
- Step lists are aligned by `(op, args)` or choice address. The first
  divergence is the first unaligned step, or the first differing result.
- Effects the alternative *would have* performed are listed as modeled, never
  as performed.
- `(claims explanation-only)` is a fixed field. The report explains the
  execution of this program under this recording and this modeled alternative
  (§5).

### 4.6 Saved scenarios and regression export

A scenario is `scenario-v1`. Its hash, the scenario identity, binds:

- the program's checked-artifact hash and entry term hash (API.1)
- the recording's content hash
- the model handler identities
- the fork list
- seed and bounds
- the Jacquard version

Any change to one of these is a different scenario. `explore export` writes an
ordinary Warp `Test`:

```jacquard
-- generated by `jacquard explore export`; scenario <hash>
planner.explored =
  Case(
    "planner: traffic=clear -> Van",
    fn () ->
      explore.replay(planner-run-log, [ChoiceFork("traffic", 1, "clear")], fn () ->
        check.true(plan.eq?(plan-delivery(sample-order()), Van), "forked decision")),
  )
```

- `planner-run-log` is a `defterm` holding the recording, so editing the
  fixture re-keys the test (Warp §7).
- `explore.replay` is the fork handler from §4.3 packaged as a library function.
  It is strict: an unmodeled or misaligned step fails the test with the
  differ's report. Rerunning the export is therefore deterministic and needs no
  network.

## 5. Explanation, Causation, And Undo

The explorer answers exactly one question:

> In this program, with every other recorded input held fixed, what does the
> program compute when this one input takes this other value?

That is a statement about the program's execution, not a causal claim about the
world. In the walkthrough, "rain and a jam caused `Hold`" is not something the
tool asserts. It shows that the program's `Hold` depended on those two values
along this path, and that changing `traffic` alone yields `Van`.

Three rules keep this honest:

- Every report and export carries `explanation-only`.
- Alternatives run only under recordings and models. A real payment, email or
  file write is never re-executed, and a recorded real action is never
  "undone": the alternative simply shows which modeled operations it would have
  attempted instead.
- A fork that relies on a model (a dreamed or scripted world) says so for each
  step. The comparison names the model identity, so "the alternative would have
  called the carrier API" is visibly a statement about the model.

## 6. Core And Host

| layer | owns |
|---|---|
| Core (this repository) | these pieces: `exploration-log-v1`; span-carrying traces; `dist.named`; the fork engine and its legality checks; the bounds; `exploration-report-v1`; `scenario-v1`; `explore.replay`; the `jacquard explore record/show/fork/enumerate/export` CLI with text rendering; and `--format json` for every report |
| Host (presentation) | an interactive, source-linked explorer. It highlights recorded steps in the editor and offers a fork control on each legal step. It renders the report side by side and exports on request. It consumes only the JSON reports and CLI commands, and needs no evaluator access |

The Host never needs evaluator internals, and Core never needs a UI. The same
report drives the CLI, CI logs and the Host view.

## 7. Compatibility

- There is no kernel, `.jqd`, `HASH_V0`, store, or host-protocol change.
- `dist.named` and `explore.replay` are new prelude identities. `net.record`,
  `test.replay` and TL.3 `replay` keep their behaviour. TL.3 is documented as
  superseded once `explore fork` ships.
- Carrying spans into traces is a runtime metadata change. It must not alter
  the value output or exit code of any existing command; EXP.1's parity tests
  pin this.
- Native: recording and fork layers are interpreter tools in v1. A natively
  built program is recorded by running its checked source under the
  interpreter, and the report says which engine produced it.

## 8. Failure Modes

| situation | behaviour |
|---|---|
| the recording's program hash differs from the checked program | refused with a new diagnostic: the scenario is for another program |
| fork of a refused step (§4.3) | a diagnostic naming the step and the rule, before anything runs |
| an unmodeled operation after the fork | alternative status `unmodeled`, with the operation and its source position |
| bounds reached | status `exhausted`, with the bound named. The run is never presented as complete |
| the alternative fails at runtime | status `failed`, with the diagnostic. The original result is unaffected |
| an impossible outcome forced with `--outside-support` | the run proceeds and the report marks it impossible under the model |

## 9. Usability Acceptance Exercise

The exercise is run once EXP.7 lands. The participant is a developer who has
written Jacquard for less than a day and has not seen this document. They
receive:

- the delivery-planner source
- one recording
- the task: "the planner held this order; find the smallest change to its
  inputs that would have sent a van, and leave a test that shows it"

The exercise passes when all of the following hold:

1. They produce the exported test within 15 minutes using only `jacquard
   explore --help` and the command output.
2. The test passes under `jacquard test` with networking disabled.
3. Asked what the report claims, they answer in terms of the program's
   execution rather than real-world causes.
4. They never invoke a live world handler.

Record the time, every command, every point of confusion and whether each
criterion held. Any failed criterion is a design bug to fix before the Host
presentation work (EXP.6) begins.

## 10. Decisions Requiring Owner Direction

1. **Named choices as a prelude function** (§4.2, recommended). The
   alternative is a new operation in a `Choice` effect. That would make names
   visible in effect rows at the cost of a new effect every model must
   discharge.
2. **Replay from the start rather than resuming a captured continuation**
   (§4.3, recommended). This is simpler and sound under once, but costs one
   full re-execution per fork.
3. **Refusing to fork `observe`** (§4.3). Changing evidence is left to editing
   the model.
4. **Interpreter-only recording in v1** (§7).

## 11. Follow-Up Backlog

Created as tracked follow-up tasks (EXP.1–EXP.7):

| id | title | layer | depends on |
|---|---|---|---|
| EXP.1 | Span-carrying traces and `exploration-log-v1` recording for world effects with codecs | Core | — |
| EXP.2 | `dist.named` addressable random choices, recorded by name | Core | EXP.1 |
| EXP.3 | Typed fork engine: legality checks, replay-from-start, modeled continuation, `unmodeled` stop, bounds | Core | EXP.1, EXP.2 |
| EXP.4 | `exploration-report-v1` comparison, text and JSON, first divergence, effect alignment, `explore enumerate` over INF.1 outcomes | Core | EXP.3, INF.1 |
| EXP.5 | `scenario-v1` identity and `explore export` to a strict `explore.replay` Warp test | Core | EXP.3, API.1 |
| EXP.6 | Host source-linked explorer over the JSON reports | Host | EXP.4, EXP.5 |
| EXP.7 | Delivery-planner demo, walkthrough transcript, and the §9 usability exercise | Docs | EXP.5 |

## 12. Validation And Measurable Acceptance

The follow-up tasks are complete when all of the following hold:

- **Walkthrough transcript.** The §3 walkthrough runs as a cram transcript,
  with byte-identical reports on every run.
- **Hermetic export.** Every exported test passes with networking unavailable,
  and fails, naming the divergent step, when the program changes that step.
- **Refusals.** Each refusal in §4.3 and §8 has a negative test with its exact
  diagnostic.
- **Bounds.** Exhaustion is reported, never silent.
- **Secrets.** No `Secret` payload appears in any log, report or export; this
  is checked by a fuzzed recording test.
- **Parity.** Existing `run`, `replay` and `test` outputs are unchanged, with
  their crams pinned.
- **Usability.** The §9 exercise is run and recorded, and its criteria hold.
