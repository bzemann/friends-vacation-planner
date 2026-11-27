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
   │  only the public Supabase URL and publishable key
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
  3. The only external package is `zod`, mapped to `npm:zod` in `supabase/functions/deno.json`. That file is created in task 9 or 10, with the first function that uses zod.
  - **Verified in task 3:** a probe function under local `supabase functions serve` (Docker) imported `../../../lib/config/base-path.ts` and returned `{"ok":true}`, so `lib/` stays at the project root and no `_shared/` fallback is needed. Deployment with `--use-api` gets checked in task 10.
- **`supabase/`** (CLI 3.x; the config file is `supabase/config.jsonc`): `migrations/` holds the schema plus RLS, `tests/database/` the pgTAP RLS tests (`npm run db:test`), and `seed.sql` the local test data (example.com addresses only).
  - **Tables:**
    - `allowlist`: no access for `anon`/`authenticated` at all; maintained in the dashboard SQL editor.
    - `profiles`: created by a trigger on `auth.users`. Readable by yourself and by people who share a trip with you; only `display_name` is updatable, and only your own.
    - `trips`: readable by members; only the owner may update the settings columns or delete.
    - `trip_members`: readable by members of the same trip; a member may leave (not the owner), and the owner may remove others. Exactly one owner per trip (partial unique index).
    - `invites`: owner only. Insert allows only `trip_id` and `expires_at` (token and `created_by` are filled in automatically), update only `revoked_at`. At most 30 days of validity, 14 days by default.
  - **No direct inserts** into `trips` or `trip_members`. Creating a trip and joining one go through security definer RPCs in task 5.
  - **Helpers** `private.is_trip_member`, `private.is_trip_owner` and `private.shares_trip_with` are security definer with `search_path ''`. They live in the non-exposed schema `private`, which avoids recursive RLS.
  - **Closed by default:** the migration revokes default privileges. New tables and sequences in `public` get nothing for `anon`/`authenticated`, and new functions get no EXECUTE for PUBLIC, `anon` or `authenticated`, in any schema. **Every new table or RPC must grant explicitly.** An RLS test guards this.
  - **Policies:** always written with `(select auth.uid())`. Every new table needs RLS, minimal grants and pgTAP tests in the same task.
- **`supabase/functions/destination-agent/`**: the only place that calls the Anthropic API. It runs in this order:
  1. Checks the JWT and trip membership.
  2. Returns the cached result if one exists (cache key: trip + window).
  3. Enforces daily limits per trip, per user and a global limit.
  4. Calls Claude with capped max_tokens and a capped number of web searches.
  5. Validates the output with zod and caches it.
- **`.github/workflows/`**: Node version from `.nvmrc` (24 LTS).
  - `ci.yml` runs on PRs to `main` and manually. Its job, named `ci`, runs `npm ci`, lint, typecheck, format:check, test, and a build with the Pages base path. It has read-only permissions.
  - `deploy.yml` runs on pushes to `main` and manually.
    - Job `build`: `configure-pages` supplies `base_path`, which becomes `NEXT_PUBLIC_BASE_PATH`; then test, build, and upload `out/`. Read-only permissions.
    - Job `deploy`: `deploy-pages`. Only this job has `pages: write` and `id-token: write`.
    - Concurrency group `pages`: a running deploy is never cancelled.
  - GitHub Pages source is "GitHub Actions". Live URL: https://bzemann.github.io/friends-vacation-planner/
  - Branch protection on `main`: PR required, status check `ci` required, 0 approvals, enforced for admins, no force pushes or deletion. Raise approvals to 1 when the collaborator joins.
- **Secrets:**
  - The Anthropic key lives only as a Supabase function secret, from a dedicated Anthropic Console workspace with a spend limit.
  - Local values go in `.env` and `supabase/functions/.env` (both gitignored); `.env.example` documents the variables.
  - The browser only ever sees the Supabase URL and the publishable key (`sb_publishable_…`).
- **Anthropic API key policy (binding, decided by Basil 2026-11-25):**
  - The app uses **only** API keys from **two dedicated Anthropic Console workspaces** for this project. It never uses Basil's personal claude.ai account, his Claude Code login, or any other key or workspace.

    | Workspace | Key | Spend limit | Where the key lives |
    |---|---|---|---|
    | `friends-vacation-planner` | `vacation-planner-prod` | about CHF 25 per month | only as a Supabase function secret (live website) |
    | `friends-vacation-planner-dev` | `vacation-planner-dev` | about CHF 5 per month | only in the gitignored `supabase/functions/.env` (local development) |

  - The separate workspaces mean local testing can never use up the live budget, and either key can be revoked without affecting the other. The prod key is never used locally, and the dev key is never set in Supabase.
  - Basil creates both keys himself and sets them himself: prod in the Supabase dashboard (Edge Functions → Secrets), not with `supabase secrets set` in the terminal, because the shell history would store the key in plain text. Dev by editing `supabase/functions/.env`. Verification: `npx supabase secrets list`, which shows names and digests only. No agent ever asks for a key, sees it, prints it, logs it or writes it into a file, a commit, a PR or a GitHub secret.
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
- Task 2 done: CI on PRs, automatic deployment to GitHub Pages on merge to `main`, Pages enabled, branch protection on `main`, Node 24 LTS pinned in `.nvmrc`.
- Task 3 done (code): Supabase CLI 3.4, base schema migration with RLS, 58 pgTAP RLS tests, seed, `docs/DEPLOYMENT.md`. The live setup with Basil follows after the merge: Supabase project (Zurich), `db push`, Anthropic workspaces and keys, GitHub variables.
- Open: tasks 4 to 18. Next is task 4 (magic-link auth with an invite-only gate).
- Note for task 4: sign-up is currently open in `supabase/config.jsonc` for both magic link and email+password. A stranger only gets an empty profile today, but task 4 must gate both routes (before-user-created hook against the allowlist or a valid invite) or turn off password sign-up.
- Known issues:
  - The local Node is 25, which is not an LTS release; Vitest 5 shows an EBADENGINE warning during install, but everything works. CI uses Node 24 from `.nvmrc`; running `nvm use` locally is optional.
  - Lockfiles need npm 11.19 or newer. Older npm versions (such as 11.6.2) leave out nested optional wasm dependencies (`@emnapi/*`), and then `npm ci` on CI fails. Basil's global npm is now 11.21.3, so a plain `npm install` is fine. npm 12 does not support Node 25.
  - Versions held back on purpose: TypeScript `~6.0.3` (typescript-eslint supports only versions below 6.1, so not TypeScript 7) and ESLint 9 (what `create-next-app` installs; it works with `eslint-config-next` 16).

## Roadmap
**M1: Scaffolding, deployment, auth, groups**
- [x] 1. Scaffold Next.js (App Router, TypeScript, Tailwind, static export, basePath through env), ESLint/Prettier/Vitest, `.env.example`, npm scripts. Confirm how `lib/` code is shared with the Deno functions.
- [x] 2. CI (`ci.yml`) and GitHub Pages deployment (`deploy.yml`); enable Pages through `gh`; first live deployment of a placeholder page.
- [x] 3. Supabase setup: CLI as devDependency, `supabase init`, base schema (profiles, trips, trip_members, invites, allowlist) with RLS, `docs/DEPLOYMENT.md` including the manual checklist (Supabase project, secrets, and a step-by-step guide for the two Anthropic Console workspaces (prod and dev), their spend limits and keys, following the API key policy). The Planner then walks Basil through it live; verify with `npx supabase secrets list`, which shows names only.
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
- Requirements: Node 24 LTS (`.nvmrc`; Node 25 also works locally), npm, and Docker (needed for local Supabase).
- Deployment: merging a PR into `main` publishes the site automatically. Watch it with `gh run watch`; a manual redeploy is `gh workflow run deploy.yml`.
- Package manager: npm. The Supabase CLI is a devDependency, run with `npx supabase` (from task 3).
- Fast checks: `./scripts/check.sh`
- Local Supabase (Docker Desktop must be running): `npm run db:start`, `npm run db:reset` (migrations + seed), `npm run db:test` (pgTAP RLS tests), `npm run db:stop`.
- Remote setup, keys and the allowlist: see `docs/DEPLOYMENT.md`. Migrations are pushed by hand with `npx supabase db push` after a merge.
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
- 2026-11-25: Task 2, CI and GitHub Pages deployment.
  - Added `ci.yml` (job `ci`) and `deploy.yml` (build, then deploy), and `.nvmrc` = 24.
  - Pages enabled with "GitHub Actions" as the source; branch protection on `main`.
  - Reviewer finding fixed: Pages and OIDC permissions are now on the deploy job only.
  - `package-lock.json` regenerated with npm 11.19.1, because the first CI run failed on missing `@emnapi/*` entries. No versions changed.
- 2026-11-27: Task 3, Supabase setup.
  - Supabase CLI 3.4 (`config.jsonc`); base schema migration (allowlist, profiles, trips, trip_members, invites) with RLS, minimal grants, `private` helpers and closed-by-default privileges.
  - 58 pgTAP RLS tests, seed with example.com addresses only, `docs/DEPLOYMENT.md`, `.env.example` switched to the publishable key, `supabase/functions/.env.example`.
  - Probe confirmed that local `functions serve` can import `lib/`.
  - Two review rounds. Fixed: docs errors; about 28 more RLS tests; 30-day invite cap; one owner per trip; global function default privilege (new functions were callable by `anon`); a test that could never fail.
  - API key policy now says the prod key is set in the dashboard.
