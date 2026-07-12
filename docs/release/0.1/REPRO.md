# Reproducing Jacquard Core 0.1

This document assumes a fresh clone on a machine with `opam` available. The
repo also has `.tool-versions` for asdf users (`opam 2.5.1`).

## Fresh Clone

```sh
git clone https://github.com/jbwinters/jacquard-lang.git
cd jacquard-lang
git checkout jacquard-core-0.1-rc3
git merge-base --is-ancestor 738dc8e HEAD

opam switch create . ocaml-base-compiler.5.1.1 -y
eval "$(opam env)"
opam install --deps-only . --with-test --with-dev-setup --with-doc -y

opam exec -- dune build @all
opam exec -- dune runtest
opam exec -- dune fmt
_build/default/bin/main.exe --version
```

Expected version:

```text
0.1.0
```

## Scripted Reproduction

Run:

```sh
scripts/release/reproduce-0.1.sh
```

The script:

- verifies that `738dc8e` is an ancestor of the checked-out release ref
- installs opam dependencies
- builds and tests the package
- runs the sanitized runtime, native differential, leak, and seeded fuzz gates
- runs `dune fmt`
- records `jacquard --version`
- packages and installs the Linux binary through the checksum-verifying public installer path
- runs public demo transcripts
- runs the gauntlet and escrow transcript
- writes generated evidence to `.scratch/release/0.1/`

The script defaults to the currently checked-out `HEAD`. Override it to verify
another local branch, tag, or immutable commit:

```sh
JACQUARD_RELEASE_REF=<commit> scripts/release/reproduce-0.1.sh
```

The output root defaults to `.scratch/release/0.1/`. Override it only with a
disposable path that has enough space for the generated transcripts and build
evidence:

```sh
JACQUARD_RELEASE_OUT=$PWD/.scratch/my-release \
  scripts/release/reproduce-0.1.sh
```

## Public Demo Coverage

| transcript | command |
|---|---|
| M1 factorial/choose/eval | public `.jac` via `sh demos/basics/m1.sh`; paired `.jqd` parity in `dune runtest test/cli/demos.t` |
| clarifying-question VOI | `sh demos/inference/clarifying-question.sh` and `dune runtest test/cli/demos.t` |
| agent dream mode | `sh demos/worlds/agent-dream.sh` and `dune runtest test/cli/demos.t` |
| ambiguity-preserving extraction | `sh demos/inference/ambiguity-pipeline.sh` and `dune runtest test/cli/demos.t` |
| Warp-backed demo checks | `sh demos/tooling/showcase-warp-tests.sh` and `dune runtest test/cli/demos.t` |
| hostile manifest | `sh demos/worlds/m4-hostile.sh` and `dune runtest test/cli/hostile-demo.t` |
| M3 same model/different handler | `sh demos/inference/m3.sh` and `dune runtest test/cli/infer.t` |
| Bayesian program repair | public `.jac` plus bootstrap Warp fixture via `sh demos/tooling/repair.sh` and `dune runtest test/cli/repair.t` |
| Surface/bootstrap carrier parity | `dune runtest test/cli/demos.t test/cli/infer.t test/cli/surface.t` |
| formatter/diff/errors/tools | `dune runtest test/cli/diff.t test/cli/tools.t test/cli/tutorial.t` |
| stdlib smoke | `dune runtest test/cli/demos.t test/cli/world.t` |
| Warp smoke | `dune runtest test/cli/warp.t test/cli/props.t` |
| gauntlet | `dune runtest test/gauntlet` and selected `gauntlet-*` Alcotest suites |
| executable escrow | `sh demos/worlds/escrow/run.sh` and `dune runtest test/cli/escrow.t` |
| release-risk case study | `sh demos/case-studies/release-risk/run.sh` and `dune runtest test/cli/case-studies.t` |
| Stormglass incident war game | `sh demos/case-studies/stormglass/run.sh` and `dune runtest test/cli/case-studies.t` |

Generated transcript files are not source artifacts; they live under
`.scratch/release/0.1/transcripts/` by default. `.scratch/` is ignored by git.
