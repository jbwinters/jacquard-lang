# Unreleased Slice Entries

Each change merged after the shared [slice log](../SLICES.md) adds one file
here, named `<YYYY-MM-DD>-<short-name>.md` for its merge date, holding the
entry that change would once have appended to the log: what it changed, the
evidence that pins it, and what it leaves for later. Entries do not record a
running test inventory; `scripts/release/inventory.sh` prints that, and the
next release freezes it. Separate files let several pull requests land in
parallel without conflicting over one log. At the release, the entries are
gathered, in date order, into that release's slice log.
