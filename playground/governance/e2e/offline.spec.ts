import { expect, test } from "@playwright/test";

test("renders locally and makes no non-loopback network request", async ({ page }) => {
  const nonLoopback: string[] = [];
  page.on("request", (request) => {
    const url = new URL(request.url());
    if ((url.protocol === "http:" || url.protocol === "https:") && url.hostname !== "127.0.0.1" && url.hostname !== "localhost") nonLoopback.push(request.url());
  });
  await page.goto("/");
  await expect(page.locator("#chain-title")).toHaveCount(1);
  await expect(page.getByText("Type-proven effect authority")).toHaveCount(1);
  expect(nonLoopback).toEqual([]);
});

test("keeps local controls and evidence reachable by keyboard", async ({ page }) => {
  await page.goto("/");
  await page.keyboard.press("Tab");
  await expect(page.getByLabel("Normalized decision artifact JSON")).toBeFocused();
  await page.keyboard.press("Tab");
  await expect(page.getByRole("button", { name: "Validate and render" })).toBeFocused();
  await page.keyboard.press("Tab");
  await expect(page.getByRole("button", { name: "Reset loaded data" })).toBeFocused();
  await page.keyboard.press("Tab");
  await expect(page.getByLabel("Select local JSON")).toBeFocused();
  await page.keyboard.press("Tab");
  await expect(page.getByRole("button", { name: "Copy Call full hash" })).toBeFocused();
  await page.keyboard.press("Tab");
  await expect(page.getByRole("listitem").first()).toBeFocused();
});

test("exposes visible focus in reduced-motion and forced-color modes", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce", forcedColors: "active" });
  await page.goto("/");
  const firstStage = page.getByRole("listitem").first();
  await firstStage.focus();
  await expect(firstStage).toBeFocused();
  expect(await page.evaluate(() => matchMedia("(prefers-reduced-motion: reduce)").matches)).toBe(true);
  expect(await page.evaluate(() => matchMedia("(forced-colors: active)").matches)).toBe(true);
  expect(await firstStage.evaluate((element) => getComputedStyle(element).outlineStyle)).not.toBe("none");
});
