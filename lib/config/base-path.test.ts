import { describe, expect, it } from "vitest";
import { normalizeBasePath } from "./base-path";

describe("normalizeBasePath", () => {
  it("returns an empty string for undefined", () => {
    expect(normalizeBasePath(undefined)).toBe("");
  });

  it("returns an empty string for an empty string", () => {
    expect(normalizeBasePath("")).toBe("");
  });

  it("returns an empty string for whitespace only", () => {
    expect(normalizeBasePath("  ")).toBe("");
  });

  it("returns an empty string for just a slash", () => {
    expect(normalizeBasePath("/")).toBe("");
  });

  it("keeps a value that already has a leading slash", () => {
    expect(normalizeBasePath("/x")).toBe("/x");
  });

  it("adds a leading slash when missing", () => {
    expect(normalizeBasePath("x")).toBe("/x");
  });

  it("strips a trailing slash", () => {
    expect(normalizeBasePath("/x/")).toBe("/x");
  });

  it("trims whitespace and normalizes a realistic base path", () => {
    expect(normalizeBasePath(" /friends-vacation-planner/ ")).toBe(
      "/friends-vacation-planner",
    );
  });

  it("collapses multiple leading slashes to one", () => {
    expect(normalizeBasePath("//x")).toBe("/x");
  });

  it("collapses a value of only slashes to an empty string", () => {
    expect(normalizeBasePath("///")).toBe("");
  });
});
