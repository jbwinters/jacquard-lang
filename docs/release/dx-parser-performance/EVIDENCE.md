# DX.6 Parser-depth performance evidence

Status: opt-in release-hardening evidence based on prepared DX.5/DX.7 head
`473942b`, which includes the SC.16 C0-C3 stack. After PR #36 lands, this
prepared-head reference must be replaced by its merged `main` commit before
DX.6 merges.

## Finding

The reported superlinear `.jac` behavior was in trivia ownership, after parsing.
For every significant token boundary, `source_atoms` filtered the complete token
list again to find comments in that one gap. A comment-free input with `T` tokens
therefore still performed `T` full-list scans: quadratic work before lowering or
checking.

DX.6 builds one ordered map from boundary offset to the comments before that
boundary. Each comment is indexed once, and each gap performs a logarithmic map
lookup. The source-byte slicing and the existing leading, trailing, inner, EOF,
and documentation ownership rules are unchanged.

The bootstrap `.jqd` quote path did not show the same superlinear growth. On the
unguarded `4493350` baseline, quote towers from 10,000 through 160,000 forms grew
from 0.54 to 0.77 seconds with a larger host stack. The old 10-million-form case
was an unbounded depth/allocation problem, not the surface trivia bug. DX.5 bounds
that path at 10,000 reader forms with E0115, and the kernel independently bounds
direct quote payloads with E0214.

## Measurements

These representative local measurements used Linux 6.14 on an AMD Ryzen 9
7950X3D. They include roughly half a second of fixed prelude startup and are
evidence of the growth curve, not portable speed claims.

| surface parenthesis depth | before DX.6 | after DX.6 |
|---:|---:|---:|
| 1,000 | 0.55 s | 0.55 s |
| 2,000 | 0.59 s | 0.55 s |
| 4,000 | 0.79 s | 0.58 s |
| 8,000 | 1.54 s | 0.61 s |
| 12,000 | 3.51 s | guarded at 10,000 |
| 20,000 | 7.14 s | guarded at 10,000 |
| 30,000 | 14.25 s | guarded at 10,000 |
| 100,000 | exceeded 10 s on guarded `a5cf53a` | 0.64 s, exact E1227 |

At depth 100,000, the bootstrap case completed in 0.53 seconds with exact E0115.
The combined opt-in check completed both carriers in 1.20 seconds. The enforced
deadline is 10 seconds to leave room for slower development machines.

## Reproduction

Build first, then run the performance lane explicitly:

```sh
eval "$(opam env)"
opam exec -- dune build @all
scripts/parser-depth-perf.sh
```

The script generates both hostile sources under `.scratch/parser-depth-perf/`,
runs `jacquard check` under a wall-clock deadline, and requires carrier-specific
diagnostics. It rejects timeouts, the E0003 host-stack backstop, `Stack_overflow`,
or an internal error. It is intentionally not part of `dune runtest`: wall-clock
checks are opt-in performance evidence, not deterministic semantic tests.

Useful overrides:

```sh
JACQUARD_PARSER_DEPTH=200000 JACQUARD_PARSER_DEADLINE=20 \
  scripts/parser-depth-perf.sh
```
