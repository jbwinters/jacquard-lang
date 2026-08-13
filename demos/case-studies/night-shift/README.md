# Night-shift

Night-shift is an unattended maintenance bot working a low-traffic window. One
program chains most of the shipped language: exact enumeration forecasts the
risk of the night, three concurrent probe tasks (each carrying its own
simulated `Net`/`Clock` world) preflight the fleet through a typed channel, a
watchdog task is cancelled as the *expected* calm outcome, a scripted approver
consents to a proposal that names the migration's exact `Code`, the deploy
token is read as a `Secret` and stays redacted in every transcript, and the
final lever is a `once`-mode operation the checker guarantees cannot fire
twice, discharged only through the granted `eval` capability.

The launcher runs five lanes: the inferred authority signatures, an ungranted
run that refuses with `E0814` after the authority-free forecast completes, the
granted run with a leak check on the token, a `jacquard relate` noninterference
check over two deterministically derived deploy-token payloads, and the Warp
suite of deterministic cases plus two properties that `--exhaustive` turns
into proofs over all 27 fleet worlds. The Warp cases stay hermetic by using
the preflight's sequential twin and a stubbed `eval`; the concurrent channel
schedule and the real evaluation are pinned by the granted lane's transcript.

```sh
sh demos/case-studies/night-shift/run.sh
```

Not exercised here: the governance gate, Judge, and audit chain run under
their own test lanes (`test/cli/props.t`, `jac governance verify-log`) rather
than public `jac run` programs.
