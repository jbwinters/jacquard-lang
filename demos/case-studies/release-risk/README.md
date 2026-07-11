# Release Risk

One release policy runs under two telemetry worlds: a concrete snapshot handler
and a discrete probabilistic handler conditioned on a failed checkout. The
surface model's row exposes `Telemetry` before either handler discharges it.

The Warp suite checks the deterministic decision, validates the exact posterior,
and exhaustively proves that all 18 service/spike worlds with a down dependency
refuse to ship.

```sh
sh demos/case-studies/release-risk/run.sh
```
