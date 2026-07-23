import { describe, expect, it } from "vitest";
import { MAX_INPUT_BYTES, validateDecisionChain } from "../src/schema";
import { sampleDecision } from "../src/fixtures";

const source = () => JSON.stringify(sampleDecision);

describe("normalized v1 decision-chain validation", () => {
  it("accepts only the normalized Workspace v0 sample", () => expect(validateDecisionChain(source()).ok).toBe(true));
  it("rejects unknown schemas, profiles, states, and hashes", () => {
    for (const mutate of [
      (value: any) => { value.schema = "jacquard-governance-decision-chain-v2"; },
      (value: any) => { value.profile = "other-v0"; },
      (value: any) => { value.stages[2].kind = "Maybe"; },
      (value: any) => { value.stages[0].call.hash = "NOT-A-HASH"; }
    ]) {
      const value = structuredClone(sampleDecision); mutate(value);
      expect(validateDecisionChain(JSON.stringify(value)).ok).toBe(false);
    }
  });
  it("rejects oversized inputs before parsing", () => {
    expect(validateDecisionChain(" ".repeat(MAX_INPUT_BYTES + 1))).toEqual({ ok: false, errors: [`Input exceeds the ${MAX_INPUT_BYTES} byte limit.`] });
  });
  it("fails closed on secret-bearing or otherwise unsupported fields", () => {
    const value = structuredClone(sampleDecision) as any;
    for (const mutate of [
      (candidate: any) => { candidate.stages[0].secret = "not allowed"; },
      (candidate: any) => { candidate.stages[1].secret = "not allowed"; },
      (candidate: any) => { candidate.stages[2].secret = "not allowed"; },
      (candidate: any) => { candidate.stages[3].secret = "not allowed"; },
      (candidate: any) => { candidate.stages[4].activity.secret = "not allowed"; },
      (candidate: any) => { candidate.stages[5].outcome.secret = "not allowed"; }
    ]) {
      const candidate = structuredClone(value);
      mutate(candidate);
      expect(validateDecisionChain(JSON.stringify(candidate)).ok).toBe(false);
    }
  });
  it("rejects provenance, evidence-limit, and state relationship drift", () => {
    for (const mutate of [
      (value: any) => { value.illustrative = false; },
      (value: any) => { value.evidence_limits.pop(); },
      (value: any) => { value.evidence_limits.reverse(); },
      (value: any) => { value.stages[2].kind = "Allow"; },
      (value: any) => { value.stages[3].proposal = null; },
      (value: any) => { value.stages[3].audit.reverse(); },
      (value: any) => { value.stages[3].audit.push({ kind: "completed-v2", hash: "c".repeat(64), subject: "audit:completion" }); },
      (value: any) => { value.stages[4].activity.kind = "attempted"; },
      (value: any) => { value.stages[5].outcome.kind = "reconciled-completed"; },
      (value: any) => { value.stages[5].outcome.completion = { kind: "client-completion", hash: "c".repeat(64), subject: "client" }; },
      (value: any) => {
        value.stages[5].outcome.external_receipt_digest = {
          kind: "external-receipt-digest",
          hash: "d".repeat(64),
          subject: "external-receipt-digest:unexpected"
        };
      },
      (value: any) => { value.stages[4].activity.kind = "no-simulator"; },
      (value: any) => { value.stages[5].outcome.simulation_not_consent = true; }
    ]) {
      const value = structuredClone(sampleDecision) as any;
      mutate(value);
      expect(validateDecisionChain(JSON.stringify(value)).ok).toBe(false);
    }
  });
});
