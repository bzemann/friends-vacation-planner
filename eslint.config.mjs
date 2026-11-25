import { builtinModules } from "node:module";
import { defineConfig, globalIgnores } from "eslint/config";
import nextVitals from "eslint-config-next/core-web-vitals";
import nextTs from "eslint-config-next/typescript";
import eslintConfigPrettier from "eslint-config-prettier";

const SHARED_CODE_MESSAGE =
  "lib/availability and lib/agent are shared with Deno Edge Functions: no Node or React/Next imports";

const nodeBuiltinNames = builtinModules.filter((m) => !m.startsWith("_"));

const eslintConfig = defineConfig([
  ...nextVitals,
  ...nextTs,
  eslintConfigPrettier,
  {
    files: ["lib/availability/**", "lib/agent/**"],
    rules: {
      "no-restricted-imports": [
        "error",
        {
          paths: [
            ...nodeBuiltinNames.map((name) => ({
              name,
              message: SHARED_CODE_MESSAGE,
            })),
            { name: "react", message: SHARED_CODE_MESSAGE },
            { name: "react-dom", message: SHARED_CODE_MESSAGE },
            { name: "next", message: SHARED_CODE_MESSAGE },
          ],
          patterns: [
            {
              group: ["node:*", "next/*", "react/*", "react-dom/*"],
              message: SHARED_CODE_MESSAGE,
            },
          ],
        },
      ],
      "no-restricted-syntax": [
        "error",
        {
          selector: "ImportExpression",
          message: SHARED_CODE_MESSAGE,
        },
      ],
    },
  },
  // Override default ignores of eslint-config-next.
  globalIgnores([
    "out/**",
    ".next/**",
    "node_modules/**",
    "supabase/functions/**",
    "next-env.d.ts",
    "coverage/**",
  ]),
]);

export default eslintConfig;
