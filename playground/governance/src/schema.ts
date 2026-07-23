export const MAX_INPUT_BYTES = 256 * 1024;
export const SCHEMA = "jacquard-governance-decision-chain-v1" as const;
export const PROFILE = "workspace-v0" as const;

const EVIDENCE_LIMITS = [
  "committed-driver-not-execution-proof",
  "external-receipt-digest-not-receipt-truth",
  "resource-scope-not-type-proof",
  "missing-completion-not-rollback"
] as const;

export type Verdict = "Allow" | "Ask" | "Block" | "Simulate";
export type Consent = "Not required" | "Approved" | "Denied" | "Escalated" | "Stale" | "Missing";
export type Outcome =
  | "not-attempted"
  | "attempt-outcome-unknown"
  | "completed-without-receipt"
  | "receipt-pending-completion"
  | "reconciled-completed";
export type Identity = { kind: string; hash: string; subject: string };
export type Authority =
  | { kind: "effect"; effect: Identity }
  | { kind: "resource"; subject: string; effect: Identity; configuration: Identity };

export interface DecisionChain {
  schema: typeof SCHEMA;
  profile: typeof PROFILE;
  source: "verified" | "fixture";
  illustrative: boolean;
  evidence_limits: string[];
  stages: [RequestStage, AssessmentStage, VerdictStage, ConsentStage, ActivityStage, OutcomeStage];
}

export interface RequestStage {
  stage: "request";
  kind: "governance-call-v0";
  subject: string;
  call: Identity;
  operation: Identity & { kind: "operation"; name: string };
  parent_call_id: Identity | null;
  authority: Authority[];
}

export interface AssessmentStage {
  stage: "assessment";
  kind: "governance-assessment-v0";
  subject: string;
  assessment: Identity;
}

export interface VerdictStage {
  stage: "verdict";
  kind: Verdict;
  subject: string;
  policy: Identity;
  policy_rule: string;
}

export interface ConsentStage {
  stage: "consent";
  kind: Consent;
  subject: string;
  proposal: Identity | null;
  audit: Identity[];
}

export interface ActivityStage {
  stage: "activity";
  subject: string;
  activity: {
    kind: "not-attempted" | "attempted" | "simulation" | "no-simulator";
    attempt: Identity | null;
    driver: Identity | null;
  };
}

export interface OutcomeStage {
  stage: "outcome";
  subject: string;
  outcome: {
    kind: Outcome;
    receipt: Identity | null;
    external_receipt_digest: Identity | null;
    completion: Identity | null;
    simulation_not_consent: boolean;
  };
}

export type Validation = { ok: true; value: DecisionChain } | { ok: false; errors: string[] };

const HASH = /^[a-f0-9]{64}$/;
const VERDICTS = new Set<Verdict>(["Allow", "Ask", "Block", "Simulate"]);
const CONSENTS = new Set<Consent>([
  "Not required",
  "Approved",
  "Denied",
  "Escalated",
  "Stale",
  "Missing"
]);
const OUTCOMES = new Set<Outcome>([
  "not-attempted",
  "attempt-outcome-unknown",
  "completed-without-receipt",
  "receipt-pending-completion",
  "reconciled-completed"
]);
const AUDIT_KINDS = new Set(["evaluated-v2", "consented-v2", "completed-v2"]);

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);
const text = (value: unknown): value is string => typeof value === "string" && value.length > 0;

function knownKeys(
  value: Record<string, unknown>,
  fields: readonly string[],
  errors: string[],
  label: string
) {
  for (const key of Object.keys(value)) {
    if (!fields.includes(key)) errors.push(`${label} has unsupported field ${key}.`);
  }
}

function identity(
  value: unknown,
  errors: string[],
  label: string,
  expectedKind?: string,
  additionalFields: readonly string[] = []
): value is Identity {
  if (!isRecord(value)) {
    errors.push(`${label} must be an identity object.`);
    return false;
  }
  knownKeys(value, ["kind", "hash", "subject", ...additionalFields], errors, label);
  if (!text(value.kind) || (expectedKind !== undefined && value.kind !== expectedKind)) {
    errors.push(`${label} has an unknown artifact kind.`);
  }
  if (!text(value.hash) || !HASH.test(value.hash)) errors.push(`${label} has malformed hash.`);
  if (!text(value.subject)) errors.push(`${label} must have an opaque subject.`);
  return true;
}

function identityOrNull(
  value: unknown,
  errors: string[],
  label: string,
  expectedKind?: string
): value is Identity | null {
  return value === null || identity(value, errors, label, expectedKind);
}

function stage(
  value: unknown,
  expected: string,
  errors: string[]
): value is Record<string, unknown> {
  if (!isRecord(value)) {
    errors.push(`${expected} stage must be an object.`);
    return false;
  }
  if (value.stage !== expected) errors.push(`Expected ${expected} at its fixed chain position.`);
  if (!text(value.subject)) errors.push(`${expected} stage must have an opaque subject.`);
  return true;
}

function exactEvidenceLimits(value: unknown): boolean {
  return (
    Array.isArray(value) &&
    value.length === EVIDENCE_LIMITS.length &&
    value.every((entry, index) => entry === EVIDENCE_LIMITS[index])
  );
}

/** Validates presentation shape and closed state relationships only.
 *
 * It never derives governance facts, evaluates policy, joins artifacts, or
 * recomputes an identity. Invalid input is rejected as one whole document.
 */
export function validateDecisionChain(input: string): Validation {
  if (new TextEncoder().encode(input).byteLength > MAX_INPUT_BYTES) {
    return { ok: false, errors: [`Input exceeds the ${MAX_INPUT_BYTES} byte limit.`] };
  }

  let raw: unknown;
  try {
    raw = JSON.parse(input);
  } catch {
    return { ok: false, errors: ["Input is not valid JSON."] };
  }
  if (!isRecord(raw)) return { ok: false, errors: ["Artifact must be a JSON object."] };

  const errors: string[] = [];
  knownKeys(
    raw,
    ["schema", "profile", "source", "illustrative", "evidence_limits", "stages"],
    errors,
    "document"
  );
  if (raw.schema !== SCHEMA) errors.push(`Unsupported schema; expected ${SCHEMA}.`);
  if (raw.profile !== PROFILE) errors.push(`Unsupported profile; expected ${PROFILE}.`);
  if (raw.source !== "verified" && raw.source !== "fixture") {
    errors.push("Document has unknown source.");
  }
  if (typeof raw.illustrative !== "boolean") {
    errors.push("Document illustrative flag must be boolean.");
  } else if (
    (raw.source === "fixture" && !raw.illustrative) ||
    (raw.source === "verified" && raw.illustrative)
  ) {
    errors.push("Document source and illustrative flag disagree.");
  }
  if (!exactEvidenceLimits(raw.evidence_limits)) {
    errors.push("Document must contain the exact ordered evidence limits.");
  }
  if (!Array.isArray(raw.stages) || raw.stages.length !== 6) {
    return { ok: false, errors: [...errors, "Document must contain exactly six ordered stages."] };
  }

  const [request, assessment, verdict, consent, activity, outcome] = raw.stages;
  if (stage(request, "request", errors)) {
    knownKeys(
      request,
      ["stage", "kind", "subject", "call", "operation", "parent_call_id", "authority"],
      errors,
      "request"
    );
    if (request.kind !== "governance-call-v0") {
      errors.push("request has an unknown artifact kind.");
    }
    identity(request.call, errors, "request.call", "governance-call-v0");
    if (!isRecord(request.operation)) {
      errors.push("request.operation must be an identity object.");
    } else {
      identity(request.operation, errors, "request.operation", "operation", ["name"]);
      if (!text(request.operation.name)) errors.push("request.operation must have a nonempty name.");
    }
    identityOrNull(
      request.parent_call_id,
      errors,
      "request.parent_call_id",
      "governance-call-v0"
    );
    if (!Array.isArray(request.authority)) {
      errors.push("request.authority must be an array.");
    } else {
      request.authority.forEach((entry, index) => {
        if (!isRecord(entry) || (entry.kind !== "effect" && entry.kind !== "resource")) {
          errors.push(`authority[${index}] has an unknown evidence kind.`);
          return;
        }
        if (entry.kind === "effect") {
          knownKeys(entry, ["kind", "effect"], errors, `authority[${index}]`);
        } else {
          knownKeys(
            entry,
            ["kind", "subject", "effect", "configuration"],
            errors,
            `authority[${index}]`
          );
          if (!text(entry.subject)) errors.push(`authority[${index}] must have opaque subject.`);
          identity(
            entry.configuration,
            errors,
            `authority[${index}].configuration`,
            "configuration"
          );
        }
        identity(entry.effect, errors, `authority[${index}].effect`, "effect");
      });
    }
  }

  if (stage(assessment, "assessment", errors)) {
    knownKeys(assessment, ["stage", "kind", "subject", "assessment"], errors, "assessment");
    if (assessment.kind !== "governance-assessment-v0") {
      errors.push("assessment has an unknown artifact kind.");
    }
    identity(
      assessment.assessment,
      errors,
      "assessment.assessment",
      "governance-assessment-v0"
    );
  }

  let verdictKind: Verdict | undefined;
  if (stage(verdict, "verdict", errors)) {
    knownKeys(verdict, ["stage", "kind", "subject", "policy", "policy_rule"], errors, "verdict");
    if (!VERDICTS.has(verdict.kind as Verdict)) {
      errors.push("verdict has unknown state.");
    } else {
      verdictKind = verdict.kind as Verdict;
    }
    identity(verdict.policy, errors, "verdict.policy", "bound-policy-v0");
    if (!text(verdict.policy_rule)) errors.push("verdict must have policy_rule text.");
  }

  let consentKind: Consent | undefined;
  if (stage(consent, "consent", errors)) {
    knownKeys(consent, ["stage", "kind", "subject", "proposal", "audit"], errors, "consent");
    if (!CONSENTS.has(consent.kind as Consent)) {
      errors.push("consent has unknown state.");
    } else {
      consentKind = consent.kind as Consent;
    }
    const proposalValid = identityOrNull(
      consent.proposal,
      errors,
      "consent.proposal",
      "governance-proposal-v0"
    );
    const committedConsent =
      consentKind === "Approved" || consentKind === "Denied" || consentKind === "Escalated";
    if (proposalValid && committedConsent !== (consent.proposal !== null)) {
      errors.push("Consent proposal presence disagrees with the consent state.");
    }
    if (!Array.isArray(consent.audit)) {
      errors.push("consent.audit must be an array.");
    } else {
      consent.audit.forEach((item, index) => {
        if (identity(item, errors, `consent.audit[${index}]`)) {
          const expectedKind = index === 0 ? "evaluated-v2" : "consented-v2";
          if (!AUDIT_KINDS.has(item.kind) || item.kind !== expectedKind) {
            errors.push(`consent.audit[${index}] has an unexpected Audit kind or order.`);
          }
        }
      });
      if (consent.audit.length > 2) {
        errors.push("Consent stage has too many Audit records.");
      }
      if (committedConsent !== (consent.audit.length === 2)) {
        errors.push("Committed consent state and consented Audit evidence disagree.");
      }
    }
  }

  let activityKind: ActivityStage["activity"]["kind"] | undefined;
  if (stage(activity, "activity", errors)) {
    knownKeys(activity, ["stage", "subject", "activity"], errors, "activity");
    if (!isRecord(activity.activity)) {
      errors.push("activity.activity must be an object.");
    } else {
      knownKeys(activity.activity, ["kind", "attempt", "driver"], errors, "activity.activity");
      if (
        !["not-attempted", "attempted", "simulation", "no-simulator"].includes(
          activity.activity.kind as string
        )
      ) {
        errors.push("activity has unknown state.");
      } else {
        activityKind = activity.activity.kind as ActivityStage["activity"]["kind"];
      }
      const attemptValid = identityOrNull(
        activity.activity.attempt,
        errors,
        "activity.attempt",
        "action-attempted-v1"
      );
      const driverValid = identityOrNull(
        activity.activity.driver,
        errors,
        "activity.driver",
        "driver"
      );
      if (
        attemptValid &&
        driverValid &&
        activityKind !== undefined &&
        ((activityKind === "attempted") !==
          (activity.activity.attempt !== null && activity.activity.driver !== null))
      ) {
        errors.push("Attempt and driver presence disagree with the activity state.");
      }
    }
  }

  let outcomeKind: Outcome | undefined;
  let simulationNotConsent: boolean | undefined;
  if (stage(outcome, "outcome", errors)) {
    knownKeys(outcome, ["stage", "subject", "outcome"], errors, "outcome");
    if (!isRecord(outcome.outcome)) {
      errors.push("outcome.outcome must be an object.");
    } else {
      knownKeys(
        outcome.outcome,
        [
          "kind",
          "receipt",
          "external_receipt_digest",
          "completion",
          "simulation_not_consent"
        ],
        errors,
        "outcome.outcome"
      );
      if (!OUTCOMES.has(outcome.outcome.kind as Outcome)) {
        errors.push("outcome has unknown state.");
      } else {
        outcomeKind = outcome.outcome.kind as Outcome;
      }
      const externalDigestValid = identityOrNull(
        outcome.outcome.external_receipt_digest,
        errors,
        "outcome.external_receipt_digest",
        "external-receipt-digest"
      );
      const receiptValid = identityOrNull(
        outcome.outcome.receipt,
        errors,
        "outcome.receipt",
        "action-receipt-v1"
      );
      const completionValid = identityOrNull(
        outcome.outcome.completion,
        errors,
        "outcome.completion",
        "completed-v2"
      );
      if (
        receiptValid &&
        completionValid &&
        outcomeKind !== undefined
      ) {
        const receiptExpected =
          outcomeKind === "receipt-pending-completion" ||
          outcomeKind === "reconciled-completed";
        const completionExpected =
          outcomeKind === "completed-without-receipt" ||
          outcomeKind === "reconciled-completed";
        if (receiptExpected !== (outcome.outcome.receipt !== null)) {
          errors.push("Receipt presence disagrees with the outcome state.");
        }
        if (
          externalDigestValid &&
          (outcome.outcome.external_receipt_digest !== null) !==
            (outcome.outcome.receipt !== null)
        ) {
          errors.push("External receipt digest presence disagrees with receipt evidence.");
        }
        if (completionExpected !== (outcome.outcome.completion !== null)) {
          errors.push("Completion presence disagrees with the outcome state.");
        }
      }
      if (typeof outcome.outcome.simulation_not_consent !== "boolean") {
        errors.push("outcome must state whether simulation is not consent.");
      } else {
        simulationNotConsent = outcome.outcome.simulation_not_consent;
      }
    }
  }

  if (
    verdictKind !== undefined &&
    consentKind !== undefined &&
    ((verdictKind === "Ask") !== (consentKind !== "Not required"))
  ) {
    errors.push("Verdict and consent states disagree.");
  }
  if (
    activityKind !== undefined &&
    outcomeKind !== undefined &&
    ((activityKind === "attempted") !== (outcomeKind !== "not-attempted"))
  ) {
    errors.push("Activity and outcome states disagree.");
  }
  if (
    simulationNotConsent !== undefined &&
    (simulationNotConsent !== (activityKind === "simulation" && verdictKind === "Simulate"))
  ) {
    errors.push("Simulation marker disagrees with the activity and verdict states.");
  }
  if (
    verdictKind !== undefined &&
    activityKind !== undefined &&
    ((verdictKind === "Simulate") !==
      (activityKind === "simulation" || activityKind === "no-simulator"))
  ) {
    errors.push("Simulation verdict and activity state disagree.");
  }

  return errors.length > 0
    ? { ok: false, errors }
    : { ok: true, value: raw as unknown as DecisionChain };
}
