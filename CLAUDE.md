# Friends Vacation Planner

## Project description
A web app where a group of friends enter the dates they are free. The app computes the time windows when all members (or at least N of M) are free, and an LLM agent (Claude) proposes cheap vacation destinations for the best windows. Results are compact cards showing destination, dates, round-trip travel, accommodation and total estimated cost per person, from each member's own home city. Clicking a card opens a detail page with travel, stay, food, activities, weather and booking links. Full brief: `PROJECT_BRIEF.md`.

Product decisions:
- **Access:** invite-only (allowlist plus trip invite links).
- **Login:** Supabase magic link email.
- **Overlap rule:** default "all members", configurable per trip to "at least N of M".
- **Group and trip size:** 2 to 10 people; trip length 3 to 14 days by default, configurable per trip.
- **Budget:** a soft preference. Results over budget are flagged and ranked lower.
- **Currency:** CHF by default, configurable.
- **API budget:** about CHF 25 per month.
- **Prices:** always labelled as estimates, with a timestamp and source links.

## Architecture and how it works
```
Browser (static Next.js export on GitHub Pages)
   │  only the public Supabase URL and anon key
   ▼
Supabase
   ├─ Auth (magic link, invite-only allowlist)
   ├─ Postgres + Row Level Security (trips, members, availability, results cache, usage counters)
   └─ Edge Functions (Deno)
        └─ destination-agent ──► Anthropic API (key stored only as a Supabase secret)
              │                   └─ web search tool
              └─ providers (interfaces: Travel / Stay / Places / Weather; mock first)
```
- **`app/`**: Next.js App Router, TypeScript, Tailwind, built as a static export (`output: "export"`) and served by GitHub Pages.
  - No server features.
  - Dynamic pages use query parameters, for example `/trip?id=…` and `/destination?trip=…&result=…`.
  - `basePath` and `assetPrefix` come from `NEXT_PUBLIC_BASE_PATH` (`/friends-vacation-planner` on Pages, empty locally), cleaned up by `normalizeBasePath` in `lib/config/base-path.ts`.
  - `next.config.ts` also sets `trailingSlash: true` (`/trip` → `trip/index.html`, which Pages finds reliably) and `images.unoptimized: true` (no image server).
  - Tailwind v4 is compiled through the `@tailwindcss/turbopack` loader in `next.config.ts`; there is no `postcss.config.mjs`. Next 16 builds with Turbopack by default, so a `next build --webpack` would not process Tailwind.
  - `agentRules: false` in `next.config.ts` stops `next dev` from generating an `AGENTS.md`; `CLAUDE.md` is the only agent instructions file (approved by Basil).
- **`lib/availability/`**: the overlap engine as pure functions.
  - It intersects date ranges, applies min/max days and minimum participants, and ranks windows by length and number of participants.
  - It is fully tested with Vitest.
- **`lib/agent/`**: zod schemas and types for the agent output (the single source of truth).
  - Every price has `estimate: true`, `retrievedAt` and `sourceUrls`.
- **`lib/providers/`**: Travel, Stay, Places and Weather interfaces, with mock implementations first.
- **Rules for shared code:** `lib/availability` and `lib/agent` are also imported by the Deno Edge Functions, through relative imports. Deployment uses `supabase functions deploy --use-api`, which supports files outside `supabase/`.
  1. No Node built-ins, no React or Next, and no dynamic `import()`. ESLint enforces this: `no-restricted-imports` builds its list from Node's `builtinModules`, and `no-restricted-syntax` forbids dynamic imports.
  2. Relative imports inside these folders include the `.ts` extension (Deno requires it; `tsconfig.json` has `allowImportingTsExtensions`).
  3. The only external package is `zod`, mapped to `npm:zod` in `supabase/functions/deno.json` (task 3).
  - Still to verify in task 3: whether local `supabase functions serve` (Docker) can see `lib/`. If not, the fallback is to move the shared code to `supabase/functions/_shared/` and import it in Next through a path alias.
- **`supabase/migrations/`**: schema plus RLS. Members can only access trips they belong to.
- **`supabase/functions/destination-agent/`**: the only place that calls the Anthropic API. It runs in this order:
  1. Checks the JWT and trip membership.
  2. Returns the cached result if one exists (cache key: trip + window).
  3. Enforces daily limits per trip, per user and a global limit.
  4. Calls Claude with capped max_tokens and a capped number of web searches.
  5. Validates the output with zod and caches it.
- **`.github/workflows/`**: `ci.yml` runs on PRs (lint, type check, tests). `deploy.yml` runs on pushes to `main` (static export, then GitHub Pages).
- **Secrets:**
  - The Anthropic key lives only as a Supabase function secret, from a dedicated Anthropic Console workspace with a spend limit.
  - Local values go in `.env` and `supabase/functions/.env` (both gitignored); `.env.example` documents the variables.
  - The browser only ever sees the Supabase URL and anon key.
- **Anthropic API key policy (binding, decided by Basil 2026-11-25):**
  - The app uses **only** API keys from **two dedicated Anthropic Console workspaces** for this project. It never uses Basil's personal claude.ai account, his Claude Code login, or any other key or workspace.

    | Workspace | Key | Spend limit | Where the key lives |
    |---|---|---|---|
    | `friends-vacation-planner` | `vacation-planner-prod` | about CHF 25 per month | only as a Supabase function secret (live website) |
    | `friends-vacation-planner-dev` | `vacation-planner-dev` | about CHF 5 per month | only in the gitignored `supabase/functions/.env` (local development) |

  - The separate workspaces mean local testing can never use up the live budget, and either key can be revoked without affecting the other. The prod key is never used locally, and the dev key is never set in Supabase.
  - Basil creates both keys himself and sets them himself: prod in the terminal with `npx supabase secrets set ANTHROPIC_API_KEY=...`, dev by editing `supabase/functions/.env`. No agent ever asks for a key, sees it, prints it, logs it or writes it into a file, a commit, a PR or a GitHub secret.
  - Code reads the key only in the Edge Function, explicitly via `Deno.env.get("ANTHROPIC_API_KEY")`. There is no fallback to any other key or variable. If the key is missing, the function fails closed: it returns a clear error, or runs in mock mode if mock mode is configured, and never calls Claude.
  - Every task that touches the agent must be checked against this policy by the Reviewer.
  - The setup steps are in `docs/DEPLOYMENT.md` (task 3). The key is needed from task 14 onwards; until then everything runs on mock providers.
- **Data sources:** provisional; the decision is made in roadmap task 13.
  - Amadeus Self-Service shut down in July 2026. Flight candidates are Duffel, Travelpayouts and RapidAPI.
  - Trains: Claude web search plus deep links to SBB, DB and Trainline.
  - Accommodation: Booking.com affiliate API, Hotellook, or Claude web search.
  - Places: OpenStreetMap. Weather: Open-Meteo.

## Workflow
- **Planner** (Opus, `~/.claude/agents/planner.md`): plans, dispatches and does a first review.
- **Executors** (`~/.claude/agents/executor.md`): implement. Each runs on Sonnet or Haiku, chosen per subagent by the Planner with Basil's approval.
- **Reviewer** (`~/.claude/agents/reviewer.md`, read-only): reviews every task independently.
- **Hook:** runs `scripts/check.sh` (Prettier, ESLint, tsc, plus `deno check` if Deno is installed) after every edit.
- Basil has the final word on every plan and every model choice. Tasks run via `/task`.
- A task is only done when tests, lint and type check pass.

## Workflow settings
- Max executors: 3
- Git flow: pr
- GitHub: public
- Remote: https://github.com/bzemann/friends-vacation-planner

## Current status
- Project setup done: Git, `.gitignore`, `scripts/check.sh`, `.claude/settings.json`, this file.
- Task 1 done: Next.js 16 static export scaffold with a placeholder page, ESLint 9, Prettier, Vitest 5, the base path helper with tests, and `.env.example`.
- Open: tasks 2 to 18. Next is task 2 (CI and GitHub Pages deployment).
- Known issues:
  - The local Node is 25, which is not an LTS release; Vitest 5 shows an EBADENGINE warning during install, but everything works. Plan for task 2: pin Node 24 LTS in CI and add `.nvmrc`.
  - Versions held back on purpose: TypeScript `~6.0.3` (typescript-eslint supports only versions below 6.1, so not TypeScript 7) and ESLint 9 (what `create-next-app` installs; it works with `eslint-config-next` 16).

## Roadmap
**M1: Scaffolding, deployment, auth, groups**
- [x] 1. Scaffold Next.js (App Router, TypeScript, Tailwind, static export, basePath through env), ESLint/Prettier/Vitest, `.env.example`, npm scripts. Confirm how `lib/` code is shared with the Deno functions.
- [ ] 2. CI (`ci.yml`) and GitHub Pages deployment (`deploy.yml`); enable Pages through `gh`; first live deployment of a placeholder page.
- [ ] 3. Supabase setup: CLI as devDependency, `supabase init`, base schema (profiles, trips, trip_members, invites, allowlist) with RLS, `docs/DEPLOYMENT.md` including the manual checklist (Supabase project, secrets, and a step-by-step guide for the two Anthropic Console workspaces (prod and dev), their spend limits and keys, following the API key policy). The Planner then walks Basil through it live; verify with `npx supabase secrets list`, which shows names only.
- [ ] 4. Magic-link auth with an invite-only allowlist (signup checks the allowlist or a valid invite) and a login page.
- [ ] 5. Create trips, generate an invite link, join through `/join?token=…`, list my trips.

**M2: Availability and overlap engine**
- [ ] 6. Overlap engine in `lib/availability` (intersection, min/max days, min participants, ranking) with thorough Vitest tests.
- [ ] 7. Availability calendar (mobile friendly, click and drag ranges), stored in the database; member profile (home city, budget, preferences).
- [ ] 8. Trip page: show the overlap windows (all members or N of M), with trip settings.

**M3: Agent with mock providers and result cards**
- [ ] 9. Zod schemas in `lib/agent`; provider interfaces with mocks in `lib/providers`.
- [ ] 10. Edge Function `destination-agent`: auth/membership check, cache table, rate limits, mock mode end to end.
- [ ] 11. Result cards (cost per person from each member's own home city, "estimate" label with timestamp and sources).

**M4: Detail page**
- [ ] 12. Destination detail page (`/destination?…`): travel, stay, food, activities, weather, booking links.

**M5: Real providers, caching, cost limits**
- [ ] 13. Research spike: compare the providers and write `docs/PROVIDERS.md`; decision by Basil.
- [ ] 14. Claude agent with web search behind the provider interface (capped max_tokens and number of web searches, zod validation, prompt-injection guards).
- [ ] 15. Weather (Open-Meteo) and places (OSM) providers; further APIs depending on the outcome of task 13.
- [ ] 16. Cost control: usage table, global daily and monthly limits, cost display, cache invalidation.

**M6: Polish**
- [ ] 17. Responsive design and accessibility pass; empty, loading and error states.
- [ ] 18. Playwright end-to-end tests of the main flow (mock mode) in CI.

## Setup and run
- Requirements: Node (25 is installed), npm, and Docker (needed for local Supabase).
- Package manager: npm. The Supabase CLI is a devDependency, run with `npx supabase` (from task 3).
- Fast checks: `./scripts/check.sh`
- First time: `npm install`. Copy `.env.example` to `.env` if you need to set values locally.
- `npm run dev`: development server at http://localhost:3000.
- `npm run build`: static export into `out/`. Use `NEXT_PUBLIC_BASE_PATH=/friends-vacation-planner npm run build` to build exactly as on GitHub Pages.
- `npm test` runs Vitest once (`lib/**/*.test.ts`); `npm run test:watch` keeps it running.
- `npm run lint`, `npm run typecheck`, `npm run format:check`, `npm run format`.
- `npm run check` runs the same fast checks as the hook.

## Changelog
- 2026-11-25: Project setup.
  - Created: Git repo, `.gitignore`, `scripts/check.sh`, `.claude/settings.json`, `CLAUDE.md`.
  - Roadmap approved.
  - Decisions: public repo, `pr` flow, at most 3 executors, magic link, invite-only, API budget about CHF 25 per month.
- 2026-11-25: Added the binding Anthropic API key policy (dedicated Console workspace key only; set by Basil himself; fail closed).
- 2026-11-25: API key policy split into prod and dev: two workspaces, two keys, separate spend limits.
- 2026-11-25: Task 1, Next.js scaffold.
  - Static export with base path from env (`normalizeBasePath`, 10 tests), Tailwind v4 through Turbopack, `agentRules: false`.
  - ESLint 9 with the shared-code import rules, Prettier (Markdown and `.claude/` ignored), Vitest 5, npm scripts, `.env.example`.
  - Reviewer findings fixed: complete Node built-in list, dynamic imports blocked, `vitest.config.mts`, repeated leading slashes collapsed.
