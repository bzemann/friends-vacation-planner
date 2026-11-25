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
  - `basePath` and `assetPrefix` come from an environment variable (`/friends-vacation-planner` on Pages).
- **`lib/availability/`**: the overlap engine as pure functions.
  - It intersects date ranges, applies min/max days and minimum participants, and ranks windows by length and number of participants.
  - It is fully tested with Vitest.
- **`lib/agent/`**: zod schemas and types for the agent output (the single source of truth).
  - Every price has `estimate: true`, `retrievedAt` and `sourceUrls`.
- **`lib/providers/`**: Travel, Stay, Places and Weather interfaces, with mock implementations first.
- **Rule for shared code:** `lib/availability` and `lib/agent` are also imported by the Deno Edge Functions, so they must stay free of Node APIs.
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
- Remote: none

## Current status
- Project setup done: Git, `.gitignore`, `scripts/check.sh`, `.claude/settings.json`, this file.
- No application code yet.
- Open: the whole roadmap. Next is task 1.
- Known issues: none.

## Roadmap
**M1: Scaffolding, deployment, auth, groups**
- [ ] 1. Scaffold Next.js (App Router, TypeScript, Tailwind, static export, basePath through env), ESLint/Prettier/Vitest, `.env.example`, npm scripts. Confirm how `lib/` code is shared with the Deno functions.
- [ ] 2. CI (`ci.yml`) and GitHub Pages deployment (`deploy.yml`); enable Pages through `gh`; first live deployment of a placeholder page.
- [ ] 3. Supabase setup: CLI as devDependency, `supabase init`, base schema (profiles, trips, trip_members, invites, allowlist) with RLS, `docs/DEPLOYMENT.md` including the manual checklist (Supabase project, secrets, Console workspace with spend limit).
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
- Build, test and dev commands will be added in task 1 (`npm run dev`, `npm run build`, `npm test`, `npm run lint`, `npm run typecheck`).

## Changelog
- 2026-11-25: Project setup.
  - Created: Git repo, `.gitignore`, `scripts/check.sh`, `.claude/settings.json`, `CLAUDE.md`.
  - Roadmap approved.
  - Decisions: public repo, `pr` flow, at most 3 executors, magic link, invite-only, API budget about CHF 25 per month.
