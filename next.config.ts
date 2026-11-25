import type { NextConfig } from "next";
import { normalizeBasePath } from "./lib/config/base-path";

const basePath = normalizeBasePath(process.env.NEXT_PUBLIC_BASE_PATH);

const nextConfig: NextConfig = {
  output: "export",
  trailingSlash: true,
  images: { unoptimized: true },
  basePath,
  assetPrefix: basePath === "" ? undefined : basePath,
  // Avoid "next dev" auto-generating an AGENTS.md; this project uses
  // CLAUDE.md as the single source of truth for agents.
  agentRules: false,
  turbopack: {
    rules: {
      "*.css": {
        loaders: ["@tailwindcss/turbopack"],
        as: "*.css",
      },
    },
  },
};

export default nextConfig;
