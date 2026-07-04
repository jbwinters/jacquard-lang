# Reproducing Weft Core 0.1

This document assumes a fresh clone on a machine with `opam` available. The
repo also has `.tool-versions` for asdf users (`opam 2.5.1`).

## Fresh Clone

```sh
git clone <repo-url> weft-lang
cd weft-lang
git checkout release/0.1-evidence
git merge-base --is-ancestor 3609a67 HEAD

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

- verifies that `3609a67` is an ancestor of the checked-out release ref
- installs opam dependencies
- builds and tests the package
- runs `dune fmt`
- records `weft --version`
- runs public demo transcripts
- runs the gauntlet and escrow transcript
- writes generated transcripts to `logs/release/0.1/`

The script defaults to `WEFT_RELEASE_REF=release/0.1-evidence`. Override it for
a final immutable commit:

```sh
WEFT_RELEASE_REF=<commit> scripts/release/reproduce-0.1.sh
```

## Public Demo Coverage

| transcript | command |
|---|---|
| M1 factorial/choose/eval | `sh demos/m1.sh` |
| clarifying-question VOI | `sh demos/clarifying-question.sh` and `dune runtest test/cli/demos.t` |
| hostile manifest | `sh demos/m4-hostile.sh` and `dune runtest test/cli/hostile-demo.t` |
| M3 same model/different handler | `sh demos/m3.sh` and `dune runtest test/cli/infer.t` |
| formatter/diff/errors/tools | `dune runtest test/cli/diff.t test/cli/tools.t test/cli/tutorial.t` |
| stdlib smoke | `dune runtest test/cli/demos.t test/cli/world.t` |
| Warp smoke | `dune runtest test/cli/warp.t test/cli/props.t` |
| gauntlet | `dune runtest test/gauntlet` and selected `gauntlet-*` Alcotest suites |
| executable escrow | `dune runtest test/cli/escrow.t` |

Generated transcript files are not source artifacts; they live under
`logs/release/0.1/`, which is ignored by git.
