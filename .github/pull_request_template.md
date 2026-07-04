## Summary

- 

## Verification

- [ ] `eval "$(opam env)"`
- [ ] `opam exec -- dune build @all`
- [ ] `opam exec -- dune runtest`
- [ ] `opam exec -- dune fmt`
- [ ] `git diff --exit-code`

## Checklist

See [CONTRIBUTING.md](../CONTRIBUTING.md) and [docs/ci-cd.md](../docs/ci-cd.md)
for the full conventions.

- [ ] I followed the active Task Master task.
- [ ] I updated tests with behavior changes.
- [ ] I kept public contracts documented.
- [ ] I did not add out-of-scope language features.
- [ ] If this is release-facing, `scripts/release/reproduce-0.1.sh` is green.
