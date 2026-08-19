# Jacquard Core 0.2 Release Decision

Status: candidate is ready for RC1 only after the exact candidate reproduction
and required GitHub checks are green.

Test count: `877`

Cram count: `59`

Documentation example count: `28` across `8` documents

## Decision

Publish `jacquard-core-0.2.0-rc1` from the reviewed merge commit when:

- the complete 0.2 manifest verifies against lineage base
  `c0f570501b751865c0c0584d9b15be08b6ec1cde`;
- development, Clang, GCC, governance, GM.12B, parser-depth, and release
  reproduction evidence are green for that exact commit;
- the binary workflow publishes three archives and three matching checksum
  files; and
- the downloaded Linux archive and public RC installer pass smoke validation.

Promote `jacquard-core-0.2.0` only by tagging that same commit after the RC
checks and assets pass. A source change requires a new reviewed commit and RC;
published tags are immutable.

## Rationale

The shipped successor surface is materially broader than the historical 0.1
candidate: public `.jac`, exporter/parser hardening, explicit dictionaries,
affine effect evidence, the closed Audit/Secret/Approval taxonomy,
interpreter structured concurrency and typed Channels, relational Warp, and
the bounded Workspace governance reference implementation are integrated and
tested together. Calling this distribution 0.2 accurately distinguishes that
integrated artifact without pretending the v0 surface or research runtime is
production-stable.

## Conditions on the Public Claim

Release notes and announcements must link `CLAIMS.md` and `LIMITS.md`. They
must not call Jacquard a sandbox, production authorization system, formally
verified compiler, human-validated readability improvement, native async
runtime, or general continuous probabilistic language.
