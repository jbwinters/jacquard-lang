Release process, fifth part: parallel pull requests. The required CI, Governance
and GM12B workflows also run on `merge_group`, so `main` can merge through a
merge queue that tests each pull request on top of the latest `main` instead of
requiring every open pull request to rebase after each merge. GM12B's scope in
the queue is the queued range, so a pull request touching the proof's closure
reruns it on the merged result. The live test inventory is no longer recorded
in `docs/release/unreleased/README.md`, `docs/release/dx-jac-export/EVIDENCE.md`
or `docs/release/structured-concurrency/EVIDENCE.md`, which every test-adding
change had to edit: `scripts/release/inventory.sh` prints it from the build,
and `test/test_surface_laws.ml` checks only released inventories, which each
release freezes at its tag. Each change now adds its own entry file here
instead of appending to the shared slice log. The release procedure says how
the next release gathers them and freezes its inventory.
