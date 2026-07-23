import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { validateDecisionChain } from "../src/schema";

// Backend-owned files: tests intentionally name the required generated examples but never create them.
const required = ["allowed.json", "blocked.json", "stale-approval.json", "transformed.json", "attempt-missing-completion.json", "dry-simulation.json"];
const fixtureDir = resolve(process.cwd(), "fixtures/generated");

describe("backend-generated decision-chain fixtures", () => {
  for (const name of required) {
    const path = resolve(fixtureDir, name);
    it(`${name} exists and validates`, () => {
      expect(existsSync(path), `${name} must be checked in`).toBe(true);
      expect(validateDecisionChain(readFileSync(path, "utf8")).ok).toBe(true);
    });
  }
});
