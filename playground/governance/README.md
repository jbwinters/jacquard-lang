# Governance decision-chain viewer

Local-only React/Vite renderer for the backend-generated
`jacquard-governance-decision-chain-v1` Workspace v0 projection. It accepts
only normalized JSON, keeps it in memory, and never fetches, persists, or
executes supplied content.

Use the pinned active-LTS runtime and package manager:

```sh
corepack enable
pnpm install --frozen-lockfile
pnpm run lint
pnpm run typecheck
pnpm run test
pnpm run build
pnpm run test:e2e
```

`pnpm run dev` and `pnpm run preview` bind to `127.0.0.1`. Backend-generated
fixtures belong in `fixtures/generated/`; expected examples are `allowed`,
`blocked`, `stale-approval`, `transformed`, `attempt-missing-completion`, and
`dry-simulation` (all `.json`).

Regenerate those files from typed OCaml values at the repository root:

```sh
JACQUARD_GOVERNANCE_PLAYGROUND_FIXTURES_OUT="$PWD/playground/governance/fixtures/generated" \
  opam exec -- dune exec test/gen_governance_playground_fixtures.exe
git diff --exit-code -- playground/governance/fixtures/generated
```

The complete trust boundary, evidence language, and reproduction contract are
in [`docs/client-playground.md`](../../docs/client-playground.md).
