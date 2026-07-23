import { useState } from "react";
import type { DecisionChain, Identity, Outcome } from "./schema";

/** Renders a backend-supplied identity without attempting to verify or reinterpret it. */
function Evidence({
  identity,
  label,
  anchor = false
}: {
  identity: Identity;
  label?: string;
  anchor?: boolean;
}) {
  const [copied, setCopied] = useState(false);
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(identity.hash);
      setCopied(true);
    } catch {
      setCopied(false);
    }
  };
  return (
    <span
      className="evidence"
      id={anchor ? `evidence-${identity.hash}` : undefined}
      tabIndex={-1}
    >
      <span className="evidence-label">{label ?? identity.kind}</span>
      <code>{identity.subject}</code>
      <code aria-label={`${label ?? identity.kind} full hash`}>{identity.hash}</code>
      <button
        type="button"
        onClick={() => void copy()}
        aria-label={`Copy ${label ?? identity.kind} full hash`}
      >
        {copied ? "Copied" : "Copy hash"}
      </button>
    </span>
  );
}

function outcomeLabel(outcome: Outcome): string {
  switch (outcome) {
    case "not-attempted": return "No action attempted";
    case "attempt-outcome-unknown": return "Attempt recorded — execution not proven";
    case "receipt-pending-completion": return "Receipt digest recorded — receipt truth not proven";
    case "completed-without-receipt": return "Completion record present — rollback not proven";
    case "reconciled-completed": return "Reconciled completion — provider truth not proven";
  }
}
function Stage({ heading, children }: { heading: string; children: React.ReactNode }) {
  return (
    <li className="stage" tabIndex={0}>
      <h2>{heading}</h2>
      {children}
    </li>
  );
}

function EvidenceLink({ target, children }: { target: string; children: React.ReactNode }) {
  return (
    <a
      href={`#evidence-${target}`}
      onClick={(event) => {
        event.preventDefault();
        document.getElementById(`evidence-${target}`)?.focus();
      }}
    >
      {children}
    </a>
  );
}

/** An ordered evidence projection. It never turns a displayed artifact into a stronger claim. */
export function DecisionChainView({ artifact }: { artifact: DecisionChain }) {
  const [request, assessment, verdict, consent, activity, outcome] = artifact.stages;
  const parentCall = request.parent_call_id;
  const proposalBindingLabel =
    consent.kind === "Approved"
      ? "Approval bound to proposal"
      : consent.kind === "Denied"
        ? "Denial bound to proposal"
        : consent.kind === "Escalated"
          ? "Escalation bound to proposal"
          : "Consent evidence bound to proposal";
  const isSimulation =
    activity.activity.kind === "simulation" && outcome.outcome.simulation_not_consent;
  const noSimulator = activity.activity.kind === "no-simulator";
  const completionMissing = outcome.outcome.kind === "attempt-outcome-unknown" || outcome.outcome.kind === "receipt-pending-completion";
  const hasOutcomeArtifact =
    outcome.outcome.receipt !== null ||
    outcome.outcome.external_receipt_digest !== null ||
    outcome.outcome.completion !== null;
  return (
    <article className="chain" aria-labelledby="chain-title">
      <header>
        <p className="eyebrow">Normalized offline artifact · {artifact.profile}</p>
        <h1 id="chain-title">Governance decision chain</h1>
        <p className={artifact.illustrative ? "fixture-notice" : "verified-notice"}>
          {artifact.illustrative
            ? "Illustrative fixture — not verified evidence"
            : "Document marked backend-verified — browser does not verify this claim"}
        </p>
        <Evidence identity={request.call} label="Call" />
      </header>
      <ol aria-label="Six-stage governance decision chain">
      <Stage heading="1. Request and authority evidence">
        <p>
          Operation: <code>{request.operation.name}</code>
        </p>
        <Evidence identity={request.operation} label="Operation" />
        <p>
          <strong>Type-proven effect authority</strong>
        </p>
        <ul>
          {request.authority
            .filter((entry) => entry.kind === "effect")
            .map((entry) => (
              <li key={entry.effect.hash}>
                <Evidence identity={entry.effect} label="Effect" />
              </li>
            ))}
        </ul>
        <p>
          <strong>Configured resource evidence — not type-proven</strong>
        </p>
        <ul>
          {request.authority
            .filter((entry) => entry.kind === "resource")
            .map((entry) =>
              entry.kind === "resource" ? (
                <li key={entry.configuration.hash}>
                  <span>{entry.subject}</span>{" "}
                  <Evidence identity={entry.effect} label="Effect" />{" "}
                  <Evidence identity={entry.configuration} label="Configuration" />
                </li>
              ) : null
            )}
        </ul>
        {parentCall ? (
          <p>
            <strong>Transformed request — new call identity</strong>{" "}
            <EvidenceLink target={parentCall.hash}>View parent call evidence</EvidenceLink>{" "}
            <Evidence identity={parentCall} label="Parent call" anchor />
          </p>
        ) : null}
      </Stage>
      <Stage heading="2. Assessment">
        <Evidence identity={assessment.assessment} label="Assessment" />
      </Stage>
      <Stage heading="3. Verdict">
        <p>
          Verdict: <strong className="status">{verdict.kind}</strong>
        </p>
        <Evidence identity={verdict.policy} label="Policy" />
        <p>{verdict.policy_rule}</p>
      </Stage>
      <Stage heading="4. Consent">
        <p>
          Consent: <strong className="status">{consent.kind}</strong>
        </p>
        {consent.proposal ? (
          <>
            <p>
              <strong>{proposalBindingLabel}</strong>
            </p>
            <Evidence identity={consent.proposal} label="Proposal" />
          </>
        ) : (
          <p>No committed artifact</p>
        )}
        {consent.kind === "Stale" ? (
          <p className="warning">
            <strong>Consent rejected — stale approval</strong>
          </p>
        ) : null}
        {consent.audit.map((entry) => (
          <Evidence key={entry.hash} identity={entry} label="Audit" />
        ))}
      </Stage>
      <Stage heading="5. Action or simulation">
        {isSimulation ? (
          <p>
            <strong>Simulation — not consent</strong>
          </p>
        ) : null}
        {noSimulator ? (
          <p className="warning">
            <strong>No simulator — no live fallback</strong>
          </p>
        ) : null}
        {activity.activity.kind === "not-attempted" ||
        activity.activity.kind === "simulation" ||
        noSimulator ? (
          <>
            <p>
              <strong>No action attempted</strong>
            </p>
            <p>No committed artifact</p>
          </>
        ) : null}
        {activity.activity.attempt ? (
          <Evidence identity={activity.activity.attempt} label="Attempt" />
        ) : null}
        {activity.activity.driver ? (
          <Evidence identity={activity.activity.driver} label="Driver" />
        ) : null}
      </Stage>
      <Stage heading="6. Outcome">
        <p>
          <strong>{outcomeLabel(outcome.outcome.kind)}</strong>
        </p>
        {completionMissing ? (
          <p className="warning">
            <strong>Outcome unknown — completion missing</strong>
          </p>
        ) : null}
        {!hasOutcomeArtifact ? <p>No committed artifact</p> : null}
        {outcome.outcome.receipt ? (
          <Evidence identity={outcome.outcome.receipt} label="Receipt" />
        ) : null}
        {outcome.outcome.external_receipt_digest ? (
          <Evidence identity={outcome.outcome.external_receipt_digest} label="Receipt digest" />
        ) : null}
        {outcome.outcome.completion ? (
          <Evidence identity={outcome.outcome.completion} label="Completion" />
        ) : null}
      </Stage>
      </ol>
    </article>
  );
}
