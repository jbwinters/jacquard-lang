import "@testing-library/jest-dom/vitest";
import { toHaveNoViolations } from "jest-axe";
import { afterEach, expect } from "vitest";
import { cleanup } from "@testing-library/react";

expect.extend(toHaveNoViolations);
afterEach(cleanup);
