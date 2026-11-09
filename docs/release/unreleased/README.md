# Jacquard Core: Unreleased

This directory carries the work integrated after `jacquard-core-0.3.0` until
the next release. The published 0.3 documents in `../0.3/`, like those in
`../0.2/`, stay byte-identical to their tag; CI refuses any change to them
(`scripts/release/check-frozen-releases.sh`). At the next release this
directory becomes that release's directory, and the inventory printed by
`scripts/release/inventory.sh` is frozen there at the tag.

## Inventory and Slice Entries

The live inventory is not recorded in any document, so parallel changes do not
conflict over it: `scripts/release/inventory.sh` prints it from the build, and
the next release freezes it at its tag. At the last recorded point it was
1246 Alcotest/QCheck cases, 85 cram transcript files and 57 documentation
examples across 9 documents.

[SLICES.md](SLICES.md) holds the slice log up to that point. Each later change
adds its own entry file under [slices/](slices/) instead of appending to a
shared log, and does not record a running inventory.

## Upgrade Notes

Notes for the next release's upgrade section, collected as changes land:

- **E0811 for field types.** A nominal type whose field type names a type
  variable its header does not declare (`type Box = | Box(value: a)`) is
  refused with E0811 (unbound type or row variable). The 0.3 notes summarise
  the nominal-field refusals without naming this code;
  `docs/effect-payload-containment.md` states the rule.
- **Rebound prelude constructors in projects with entries.** A root project
  that runs an entry may declare its own type with a prelude type's name and
  constructors (for example `opaque type Bool = | False | True`); the entry
  check no longer refuses it (E1731). An entry's own constructor that collides
  with a visible one is still E1731, and E1731 now names the root's own
  constructors as `of this project`.
