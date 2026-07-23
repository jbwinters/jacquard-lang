import { axe } from "jest-axe";
import { prettyDOM, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { DecisionChainView } from "../src/DecisionChainView";
import { fixtures, sampleDecision } from "../src/fixtures";

describe("DecisionChainView", () => {
  it("renders semantic evidence boundaries and has no basic axe violations", async () => {
    const { container } = render(<DecisionChainView artifact={sampleDecision} />);
    expect(screen.getByText("Type-proven effect authority")).toBeVisible();
    expect(screen.getByText("Configured resource evidence — not type-proven")).toBeVisible();
    expect(screen.getByText("Approval bound to proposal")).toBeVisible();
    expect(screen.getByText("Transformed request — new call identity")).toBeVisible();
    expect(screen.getByText("Illustrative fixture — not verified evidence")).toBeVisible();
    const snapshot = (prettyDOM(container, undefined, { highlight: false }) || "").replace(
      /[ \t]+$/gm,
      ""
    );
    await expect(snapshot).toMatchFileSnapshot(
      "./snapshots/DecisionChainView.test.tsx.snap"
    );
    expect(await axe(container)).toHaveNoViolations();
  });
  it("never portrays simulation as approval or resources as type proof", () => {
    const artifact = structuredClone(sampleDecision);
    artifact.stages[2].kind = "Simulate";
    artifact.stages[3].kind = "Not required";
    artifact.stages[3].proposal = null;
    artifact.stages[4].activity.kind = "simulation";
    artifact.stages[5].outcome.simulation_not_consent = true;
    render(<DecisionChainView artifact={artifact} />);
    expect(screen.getByText("Simulation — not consent")).toBeVisible();
    expect(screen.queryByText("Approval bound to proposal")).not.toBeInTheDocument();
    expect(screen.getByText("Configured resource evidence — not type-proven")).toBeVisible();
  });
  it.each([
    ["Denied", "Denial bound to proposal"],
    ["Escalated", "Escalation bound to proposal"]
  ] as const)("labels %s proposal evidence without implying approval", (kind, label) => {
    const artifact = structuredClone(sampleDecision);
    artifact.stages[3].kind = kind;
    render(<DecisionChainView artifact={artifact} />);
    expect(screen.getByText(label)).toBeVisible();
    expect(screen.queryByText("Approval bound to proposal")).not.toBeInTheDocument();
  });
  it("distinguishes an attempt, receipt, completion, and missing outcome", () => {
    const attempted = structuredClone(fixtures.attemptMissingCompletion);
    const { rerender } = render(<DecisionChainView artifact={attempted} />);
    expect(screen.getByText("Receipt digest recorded — receipt truth not proven")).toBeVisible();
    expect(screen.getByText("Outcome unknown — completion missing")).toBeVisible();
    const completed = structuredClone(sampleDecision);
    completed.stages[5].outcome.kind = "completed-without-receipt";
    completed.stages[5].outcome.receipt = null;
    completed.stages[5].outcome.completion = {
      kind: "completed-v2",
      hash: "c".repeat(64),
      subject: `audit:${"c".repeat(64)}`
    };
    rerender(<DecisionChainView artifact={completed} />);
    expect(screen.getByText("Completion record present — rollback not proven")).toBeVisible();
    expect(screen.getByLabelText("Completion full hash")).toBeVisible();
    const unknown = structuredClone(fixtures.attemptMissingCompletion);
    unknown.stages[5].outcome.kind = "attempt-outcome-unknown";
    unknown.stages[5].outcome.receipt = null;
    unknown.stages[5].outcome.external_receipt_digest = null;
    rerender(<DecisionChainView artifact={unknown} />);
    expect(screen.getByText("Attempt recorded — execution not proven")).toBeVisible();
  });
  it("renders hostile text as text, not executable markup", () => {
    const artifact = structuredClone(sampleDecision);
    artifact.stages[0].operation.name = '<img src=x onerror="alert(1)">';
    render(<DecisionChainView artifact={artifact} />);
    expect(screen.getByText('<img src=x onerror="alert(1)">')).toBeVisible();
    expect(document.querySelector("img")).toBeNull();
  });
  it("supports keyboard focus and full-hash copying", async () => {
    const user = userEvent.setup();
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, "clipboard", { configurable: true, value: { writeText } });
    render(<DecisionChainView artifact={sampleDecision} />);
    const stage = screen.getByRole("heading", { name: "1. Request and authority evidence" }).closest("li")!;
    stage.focus();
    expect(document.activeElement).toBe(stage);
    const copy = screen.getByRole("button", { name: "Copy Call full hash" });
    await user.click(copy);
    expect(writeText).toHaveBeenCalledWith(sampleDecision.stages[0].call.hash);
  });
  it("renders no-simulator refusal without implying fallback", () => {
    const artifact = structuredClone(fixtures.drySimulation);
    artifact.stages[4].activity.kind = "no-simulator";
    artifact.stages[5].outcome.simulation_not_consent = false;
    render(<DecisionChainView artifact={artifact} />);
    expect(screen.getByText("No simulator — no live fallback")).toBeVisible();
    expect(screen.getAllByText("No action attempted")).toHaveLength(2);
    expect(screen.queryByText("Simulation — not consent")).not.toBeInTheDocument();
    expect(screen.queryByText("Approval bound to proposal")).not.toBeInTheDocument();
  });
});
