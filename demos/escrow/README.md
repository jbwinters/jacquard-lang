# The executable escrow

One product-shaped walk through what makes Jacquard unusual, using only shipped
machinery (release 0.1; the full transcript is pinned in `test/cli/escrow.t`):

1. `workflow.jqd` is a generated-looking publish workflow.
2. `jacquard check --print-sigs` prints its signature — the row IS its manifest:
   `() ->{fs, console, net} int`, and NOT eval.
3. Running it without grants refuses (E0814) before anything happens.
4. `jacquard run --dry-run` renders what it WOULD do — no grants, no mutation.
5. `jacquard test tests.jqd` runs the hermetic suite (scripted worlds, no grants).
6. `jacquard test --exhaustive` PROVES the status-classifier property (400 cases).
7. The fault case explores every single/double fault assignment via fault.all.
8. `net.record`/`test.replay` capture and strictly replay the scripted run.
9. A comment-only edit hashes identically; provenance stamps ride sidecars —
   `jacquard diff` says "no semantic changes".
10. `workflow-escalated.jqd` requests authority beyond the approved manifest
    (an added eval-code call): the row gains {eval}, the escrow grant set
    refuses it, and the semantic diff localizes the escalating subtree.
11. `APPROVAL` records the reviewer-approved member hash — approval by exact
    content, not by filename or diff review.
12. Any semantic change to the workflow invalidates the approval hash.
