import { expect, test } from "@playwright/test";

function channelToLinear(channel: number): number {
  const value = channel / 255;
  return value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
}

function luminance(cssColor: string): number {
  const channels = cssColor.match(/\d+(?:\.\d+)?/g)?.slice(0, 3).map(Number);
  if (!channels || channels.length !== 3) throw new Error(`Unsupported color: ${cssColor}`);
  return (
    0.2126 * channelToLinear(channels[0]) +
    0.7152 * channelToLinear(channels[1]) +
    0.0722 * channelToLinear(channels[2])
  );
}

function contrastRatio(foreground: string, background: string): number {
  const lighter = Math.max(luminance(foreground), luminance(background));
  const darker = Math.min(luminance(foreground), luminance(background));
  return (lighter + 0.05) / (darker + 0.05);
}

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

test("keeps text readable when the browser prefers a dark color scheme", async ({ page }) => {
  await page.emulateMedia({ colorScheme: "dark" });
  await page.goto("/");
  for (const selector of [".loader", ".chain", ".stage", "button"]) {
    const colors = await page.locator(selector).first().evaluate((element) => {
      const style = getComputedStyle(element);
      return { foreground: style.color, background: style.backgroundColor };
    });
    expect(contrastRatio(colors.foreground, colors.background)).toBeGreaterThanOrEqual(4.5);
  }
});
