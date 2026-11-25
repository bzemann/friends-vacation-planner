/**
 * Normalizes a base path value coming from the NEXT_PUBLIC_BASE_PATH
 * environment variable.
 *
 * Rules:
 * - undefined, empty, or whitespace-only -> ""
 * - trims surrounding whitespace
 * - collapses any leading slashes to exactly one leading "/"
 * - strips trailing slashes
 * - collapses to "" if the result is just "/"
 */
export function normalizeBasePath(raw: string | undefined): string {
  if (raw === undefined) {
    return "";
  }

  const trimmed = raw.trim();

  if (trimmed === "") {
    return "";
  }

  const withoutLeadingSlashes = trimmed.replace(/^\/+/, "");
  const withLeadingSlash = `/${withoutLeadingSlashes}`;
  const withoutTrailingSlashes = withLeadingSlash.replace(/\/+$/, "");

  if (withoutTrailingSlashes === "") {
    return "";
  }

  return withoutTrailingSlashes;
}
