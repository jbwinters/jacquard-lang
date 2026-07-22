# Governed Membranes Claims

Status: GM.22 bounded publication matrix for the deterministic Workspace v0
research reference implementation.

Statuses mean:

- `shipped`: the stated Workspace v0 behavior is implemented and directly
  exercised;
- `bounded`: an implemented subset is advertised with an adjacent exclusion.

No row means that a hash proves correctness, truth, safety, authorization, or
human review. HASH_V0 proves canonical identity relative to the bytes and
trusted inputs supplied to it. Chain hashes prove predecessor consistency
relative to a trusted published head. The limits for both are part of every
claim below.

## D61-D73 claim matrix

| ID | status | advertised Workspace v0 claim | executable positive evidence | negative case and boundary |
|---|---|---|---|---|
| D61 | shipped | The governed interface is the typed three-operation `Workspace` facade; no universal stringly `Tool.call` is accepted. | [`test_workspace.ml`](../../../test/test_workspace.ml) pins the interface, operation inventory, typed specs, normalizers, and summaries; GM.16 admits only the exact facade grammar. | Generic forged-spec construction and wrong facade/operation identities fail in `test_workspace.ml`, [`test_governance_source_check.ml`](../../../test/test_governance_source_check.ml), and [`governance-check.t`](../../../test/cli/governance-check.t). This says nothing about an unverified user-defined facade. |
| D62 | shipped | Live Workspace drivers expose concrete `Fs`, `Net`, and `Secret` effects; no opaque `Host` effect exists. | [`test_workspace_live.ml`](../../../test/test_workspace_live.ml) pins the exact operation-specific raw rows and counters; [`test_governance_source_check.ml`](../../../test/test_governance_source_check.ml) derives the same envelopes. | Raw operations outside exact trusted boundaries fail the GM.16 source gate with E1407. Root grants remain whole-effect and are not resource isolation. |
| D63 | shipped | `Judge` is a blessed once effect whose deterministic handlers validate `GovernanceAssessment` before resumption. | [`test_judge.ml`](../../../test/test_judge.ml), [`test_effect_taxonomy.ml`](../../../test/test_effect_taxonomy.ml), and the operation-mode manifest pin identity, mode, rows, fixed/rules/scripted behavior, and refusal. | A rules callback with raw `Net`, malformed assessment, or exhausted script is refused. A Judge is trusted judgment input, not proof that its assessment is true. |
| D64 | bounded | Workspace operations return `Result ToolError a`; on ordinary completed branches each facade clause consumes its local affine `Resume` once. | [`test_workspace_dry_run.ml`](../../../test/test_workspace_dry_run.ml), [`test_workspace_live.ml`](../../../test/test_workspace_live.ml), [`test_workspace_forward.ml`](../../../test/test_workspace_forward.ml), and the native once gauntlet pin one-resume behavior and typed refusals. | Audit or driver failure may stop before resumption. Completion-write failure occurs after an external action and cannot roll it back. No exactly-once external-action claim is made. |
| D65 | shipped | Live and dry policies and entry points are distinct; the dry Workspace boundary has no raw world, consent, or `Secret` row. | GM.6's 300-case gate law, [`workspace-dry-run-laws.jqd`](../../../test/cli/workspace-dry-run-laws.jqd), [`test_workspace_dry_run.ml`](../../../test/test_workspace_dry_run.ml), and the GM.18 dry world pin an empty fully handled row and zero raw counters. | Raw authority, approval, or `Secret` appearing in the dry dependency closure is rejected. This does not establish simulator fidelity. |
| D66 | shipped | Simulation is explicit and pure; missing or failing simulation returns a typed dry result and never falls back live. | The GM.6 gate matrix, GM.10's 36 exhaustive handler cases, and [`test_workspace_dry_run.ml`](../../../test/test_workspace_dry_run.ml) cover missing, successful, and failing simulators for all operations. | Simulator absence and typed failure both prove zero live-driver calls. A simulator may still model reality incorrectly. |
| D67 | shipped | Call ID binds operation, canonical arguments, transitive raw-authority envelope, preconditions, and optional parent; Proposal ID additionally binds Call, policy, assessment, authority, preview, rendering, and summary. | [`test_governance_core.ml`](../../../test/test_governance_core.ml), [`test_workspace.ml`](../../../test/test_workspace.ml), and [`test_governance_run_bundle.ml`](../../../test/test_governance_run_bundle.ml) pin exact goldens, stability, sensitivity, recomputation, and cross-artifact linkage. | Forged carried hashes, changed semantic fields, mismatched artifacts, and misleading operation-name/hash pairs fail closed. Identity is not semantic correctness or authorization. |
| D68 | bounded | Each frozen Workspace operation has one exact transitive raw-effect envelope, checked against the live/forward action graph and displayed separately from configured resource evidence. | [`test_governance_verify.ml`](../../../test/test_governance_verify.ml), [`test_governance_verify_v1.ml`](../../../test/test_governance_verify_v1.ml), GM.16 source reports, and native `g38-governance-authority.jqd` pin equality and ordering. | Missing, duplicate, reversed, expanded, or stale authority fails verification. Resource scope strings are configured review evidence, never a row proof or path/domain enforcement. |
| D69 | bounded | One `with-sequence` owner provides contiguous Audit positions; acknowledged `Evaluated` precedes action/simulation, exact consent is recorded before an approved action, and completed ordinary outcomes are linked. | [`test_governance_gate.ml`](../../../test/test_governance_gate.ml), [`test_audit_chain.ml`](../../../test/test_audit_chain.ml), [`test_workspace_forward.ml`](../../../test/test_workspace_forward.ml), and GM.15's 698 paths pin order, fail-stop prefixes, and chain mutation refusal. | Pre-action Audit failure prevents action. Completion-Audit failure cannot undo an action and leaves an explicit reconciliation gap; Audit does not imply a trusted clock or transactional compliance store. |
| D70 | bounded | Review artifacts carry `SecretRef`, not secret bytes; allowed live drivers resolve and expose the secret only after governance and immediately before the raw action that needs it. | [`test_workspace.ml`](../../../test/test_workspace.ml), [`test_workspace_live.ml`](../../../test/test_workspace_live.ml), the non-vacuous GM.11 leak scan, and GM.18 raw-order counters pin the boundary. | Strict refusal and durable denial prove zero secret access. After explicit `secret.expose`, Jacquard provides no taint tracking or exfiltration prevention. |
| D71 | bounded | Re-performing an unchanged Workspace operation preserves its Call identity, shares Audit sequence ownership, and can only tighten through ordinary nested policies. | [`test_workspace_forward.ml`](../../../test/test_workspace_forward.ml), [`workspace-forward-laws.jqd`](../../../test/cli/workspace-forward-laws.jqd), GM.18 inner-Allow/outer-Block, and the mandatory 50,000-case GM.12B law pin unchanged forwarding. | Wrong-operation, skipped-layer, argument drift, and sequence reset fail. Every inner/outer policy pair is accepted; effective permission is conjunctive, so a permissive layer cannot erase another layer's refusal. Runtime transformed-call forwarding is not shipped; only its versioned parent/new-ID verifier contract exists. |
| D72 | shipped | Deterministic v0 policy never turns under-confidence into `Allow`; posterior uncertainty and model-backed belief policy are excluded. | [`test_governance_core.ml`](../../../test/test_governance_core.ml), [`governance-policy-laws.jqd`](../../../test/cli/governance-policy-laws.jqd), and GM.4's nine exhaustive laws pin confidence and risk monotonicity. | G5 beliefs, posterior replay, model truth, and uncertainty-aware safety are not advertised. `judge.model` still returns the same validated v0 point assessment with visible `Infer`. |
| D73 | shipped | A governed source body carrying `Eval` is rejected before membrane execution. | [`test_governance_source_check.ml`](../../../test/test_governance_source_check.ml) and [`governance-check.t`](../../../test/cli/governance-check.t) pin direct and syntactically handled Eval findings and E1412 refusal. | No live or dry exception exists. Dynamic code remains on the root-authority interpreter boundary until Eval becomes scoped or interposed. |

## Exact identity and format pins

These are review anchors, not security conclusions:

| artifact | exact HASH_V0 identity or format anchor | proving evidence |
|---|---|---|
| `code.hash` | `83b76604ebb921438d4ff5ae92173fad8c1d527dc91ae1e39c419ad5310d0c44` | `test_governance_core.ml` and prelude goldens |
| `GovernanceCall` type | `20824137b34985dabf9e6bb0c20cf9987c1ca93b5cdd8d1da60cbc69550efc27` | `test_governance_core.ml` |
| `GovernanceProposal` type | `c3acd6332f0fdb23bcc800edd64a11192d2744cc824447fbbd7c8d6069f487b8` | `test_governance_core.ml` |
| `Judge` interface | `9b677b5e2c3ec8521c5d5dfac321ae361a959565e1cbf082fec4512199977354` | `test_judge.ml` and taxonomy v2 |
| `Audit` v2 interface | `40bc4343fb2b4bcc18b18f63f7bb68675b746751bb40b876072e622046a81372` | `test_audit.ml` and `test_approval.ml` |
| `GovernanceApprovalV1` interface | `41b449689fb30e44180185007d845bbe246e5401fe3e8478f4fd02e556a3f2ed` | `test_approval.ml`, `test_governance_gate.ml`, and taxonomy v2 |
| `Workspace` interface | `d5831f495fdb26e05d53d886786f07230f7bb808ac4933ab32e0a9238c89f9d0` | `test_workspace.ml` and taxonomy v2 |
| Workspace operations: read / write / fetch | `632071e3399c913a672c4bea7d4a8b394e64a9a517552eb296db824222fe2da1` / `73140dde8e33c268fa589d9bfaeb28b156af2da52b22779257b2d3e9b696b03c` / `f6536683575508ddcc2d5a6509df832e92897cbef2caf34219f993a110079b01` | `test_workspace_forward.ml` and prelude goldens |
| Audit chain v2 | `audit-entry-v2` in `audit-chain-v2`; genesis `e30304e99930d8bf631a0b1f364b6d91f6dc798a14c7c0a554ff994ff14ab937`; three-entry golden head `7719453dca00408a09e360a3b70a4ef2ae6f742f45e03e1db49b8c6daa3d6e7e` | `test_audit_chain.ml` and `corpus/golden/audit-chain-v2*` |
| Approval queue v1 | `governance-approval-queue-record-v1` plus separate commit; genesis `a830520c64d4dd55483b1829c289866e74fdec839a3fc12d6fcdc6da760e10ed` | `test_governance_approval_queue.ml` |
| Portable run/reconciliation formats | `governance-run-bundle-v1`, `governance-action-chain-v1`, and `governance-reconciliation-bundle-v1` | `test_governance_run_bundle.ml`, `test_governance_reconcile.ml`, and their CLI transcripts |

The queue, Audit, action-journal, and overlay manifests use different domains
and answer different questions. They are not interchangeable attestations.
