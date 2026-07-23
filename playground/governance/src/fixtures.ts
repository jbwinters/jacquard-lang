import allowedJson from "../fixtures/generated/allowed.json";
import attemptMissingCompletionJson from "../fixtures/generated/attempt-missing-completion.json";
import blockedJson from "../fixtures/generated/blocked.json";
import drySimulationJson from "../fixtures/generated/dry-simulation.json";
import staleApprovalJson from "../fixtures/generated/stale-approval.json";
import transformedJson from "../fixtures/generated/transformed.json";
import { type DecisionChain, validateDecisionChain } from "./schema";

function backendFixture(value: unknown, name: string): DecisionChain {
  const result = validateDecisionChain(JSON.stringify(value));
  if (!result.ok) {
    throw new Error(`Invalid backend-generated fixture ${name}: ${result.errors.join(" ")}`);
  }
  return result.value;
}

/** Typed, runtime-validated views of the checked-in backend-generated examples. */
export const fixtures = {
  allowed: backendFixture(allowedJson, "allowed.json"),
  blocked: backendFixture(blockedJson, "blocked.json"),
  staleApproval: backendFixture(staleApprovalJson, "stale-approval.json"),
  transformed: backendFixture(transformedJson, "transformed.json"),
  attemptMissingCompletion: backendFixture(
    attemptMissingCompletionJson,
    "attempt-missing-completion.json"
  ),
  drySimulation: backendFixture(drySimulationJson, "dry-simulation.json")
} as const;

export const sampleDecision = fixtures.transformed;
