import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it } from "vitest";
import App from "../src/App";

describe("App", () => {
  it("clears stale rendered evidence while input changes and focuses rejection", async () => {
    const user = userEvent.setup();
    render(<App />);
    expect(screen.getByRole("heading", { name: "Governance decision chain" })).toBeVisible();

    const editor = screen.getByLabelText("Normalized decision artifact JSON");
    await user.clear(editor);
    await user.type(editor, "{{");
    expect(screen.queryByRole("heading", { name: "Governance decision chain" })).not.toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "Validate and render" }));
    const error = screen.getByRole("alert");
    expect(error).toHaveFocus();

    await user.click(screen.getByRole("button", { name: "Reset loaded data" }));
    expect(editor).toHaveFocus();
    expect(editor).toHaveValue("");
  });

  it("keeps the local file chooser in the keyboard order", async () => {
    const user = userEvent.setup();
    render(<App />);
    await user.tab();
    expect(screen.getByLabelText("Normalized decision artifact JSON")).toHaveFocus();
    await user.tab();
    expect(screen.getByRole("button", { name: "Validate and render" })).toHaveFocus();
    await user.tab();
    expect(screen.getByRole("button", { name: "Reset loaded data" })).toHaveFocus();
    await user.tab();
    expect(screen.getByLabelText("Select local JSON")).toHaveFocus();
  });
});
