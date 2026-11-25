# Friends Vacation Planner: Build Brief for Claude Code

## Goal
A web app where a group of friends enter the dates they are free. The app finds the time windows where everyone overlaps, and an LLM agent searches for cheap vacation destinations for those windows. Results are shown as compact cards; clicking a card opens a detail page with more information about the destination.

## Core user flow
1. A user creates a group (a "trip") and invites friends with a share link.
2. Each member marks their free dates in a calendar (click or drag date ranges), sets their home departure city, and optionally a budget and preferences (beach, city, hiking, party, culture, etc.).
3. The overlap engine computes the windows where all members (or a configurable minimum number) are free, respecting a minimum and maximum trip length.
4. For the best windows, the destination agent proposes cheap destinations.
5. Results appear as cards showing:
   - Destination (city, country, image)
   - Dates
   - Round trip travel (flight or train) with price per person
   - Accommodation (Airbnb or hotel) with price per night and total per person
   - Total estimated cost per person
6. Clicking a card opens a detail page with: travel options, accommodation options, food places, activities, weather and season info, and links to the booking sites.

## Functional requirements
- Groups, members, invite links, simple auth (magic link email or OAuth).
- Mobile friendly availability calendar.
- Overlap engine as pure, well tested logic: interval intersection over all members, parameters for min days, max days and min participants, ranking of windows by length and number of participants.
- Destination agent:
  - Input: overlap windows, each member's origin, budget, preferences.
  - Output: strict JSON validated with a schema (zod).
  - Prices must be labeled as estimates with a timestamp and source links. Never present invented numbers as real prices.
  - Cache results per group and window to control API cost.
- Members can have different origins: show cost per person from their own origin.
- Default currency CHF, configurable.

## Data sources (research before implementing)
Research the available options and propose them in the plan before building:
- Flights: price APIs or search APIs with a usable free/dev tier.
- Trains: e.g. SBB, DB, Trainline or similar.
- Accommodation: note that Airbnb has no open public API; evaluate alternatives (affiliate APIs, LLM web search with links).
- Places, food and activities: e.g. Google Places, OpenStreetMap, or LLM web search.
Put every provider behind an interface so it can be swapped. Start with a mock provider so the full flow works end to end before real APIs are connected.

## Tech stack (proposal, challenge it in the plan if something fits better)
- Next.js (App Router) with TypeScript and Tailwind, built as a **static export** (`output: "export"`) so it can be hosted on GitHub Pages
- Supabase as backend: Postgres database, auth, Row Level Security, and Edge Functions
- Anthropic API (Claude) with tool use and web search for the destination agent, called **only** from a Supabase Edge Function (never from the browser)
- Vitest for unit tests, Playwright for end to end tests
- Supabase CLI for local development (local Postgres and functions)

## Suggested structure
- `app/` UI and routes (client side only, no Next.js server features)
- `lib/availability/` pure overlap logic plus tests
- `lib/agent/` shared zod schemas and types for the agent output
- `lib/providers/` travel, stay, places provider interfaces (mock first)
- `supabase/migrations/` database schema and RLS policies
- `supabase/functions/` Edge Functions (destination agent, provider calls)
- `.github/workflows/` CI and deployment
- `docs/DEPLOYMENT.md` hosting setup and manual steps

## Hosting (GitHub Pages)
The website must be hosted via GitHub Pages, deployed automatically by GitHub Actions.

Important constraint: GitHub Pages only serves static files. It cannot run a server, hold secrets or host a database. Therefore:
- The frontend is a static Next.js export served by GitHub Pages.
- Everything that needs a server or a secret (database, auth, LLM calls, provider API keys) lives in Supabase. The browser only ever gets the public Supabase URL and anon key; all access is protected by Row Level Security.
- Set `basePath` and `assetPrefix` so the site works under `https://<user>.github.io/<repo>/` (and can later move to a custom domain).
- Use routing that works with static export: dynamic pages (e.g. a destination detail page) use query parameters or `generateStaticParams`, since there is no server to render unknown paths. Add a `404.html` fallback if needed.

Deployment pipeline to set up:
1. `.github/workflows/ci.yml`: on every pull request, run lint, type check and tests.
2. `.github/workflows/deploy.yml`: on push to `main`, build the static export and deploy it with the official `actions/upload-pages-artifact` and `actions/deploy-pages` actions.
3. Optionally deploy Supabase migrations and Edge Functions from a workflow as well (`supabase db push`, `supabase functions deploy`), using a `SUPABASE_ACCESS_TOKEN` repository secret.

What Claude should configure itself (with `gh`, after asking Basil):
- Enable GitHub Pages with source "GitHub Actions": `gh api -X POST repos/<owner>/<repo>/pages -f build_type=workflow` (or `PUT` if Pages already exists).
- Set repository secrets and variables: `gh secret set ...` and `gh variable set ...` (for example `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_REF`). Basil types the secret values himself in the terminal; Claude never sees or writes them into files.
- Verify the first deployment with `gh run watch` and report the live URL.

If any step fails or is not possible (for example: GitHub Pages on a **private** repository requires a paid GitHub plan, or the Supabase project does not exist yet), do not work around it. Instead write the missing steps as a clear manual checklist into `docs/DEPLOYMENT.md` and tell Basil, including:
- creating the Supabase project and where to find the URL, anon key and project ref
- setting the Anthropic API key as a Supabase function secret (`supabase secrets set ANTHROPIC_API_KEY=...`)
- enabling Pages in the GitHub web UI (Settings > Pages > Source: GitHub Actions) if the API call fails
- the options if the repo is private and Pages is not available on the current plan (make the repo public after a secret check, or upgrade the plan)

## Way of working (planner/executor loop)
- This project uses Basil's Planner-Executor workflow: the Planner plans, executors implement, the Reviewer reviews independently, Basil approves between phases.
- Setup runs via `/new-project` with this brief: ask the open questions below, then turn the milestones into a Roadmap in CLAUDE.md, with tasks small enough for one `/task` run each. No application code during setup.
- Recommended settings: `Git flow: pr` (two people work on this repo). Repo visibility depends on the GitHub Pages question below.
- Every later `/task` run takes one item from the Roadmap and ticks it off in the wrap-up.
- When subtasks are independent (e.g. overlap engine vs. calendar UI), the Planner may run several executors in parallel.
- A task is only done when tests, lint and type check pass.
- Secrets live in `.env` (never committed); provide `.env.example`.

## Milestones
1. Scaffolding, deployment pipeline to GitHub Pages and Supabase, auth, groups, invite links
2. Availability calendar and overlap engine with tests
3. Destination agent with mock providers, result cards
4. Detail page (travel, stay, food, activities)
5. Real providers, caching, cost limits for LLM and API calls
6. Polish and responsive design

Note: the deployment pipeline (CI, GitHub Pages deploy, Supabase setup, `docs/DEPLOYMENT.md`) belongs in milestone 1, so every merged PR is live right away.

## Non goals for v1
- Booking or payments inside the app
- Native mobile apps

## Open questions to ask us before starting
- Should the overlap require all friends, or allow "at least N of M"?
- Typical group size and trip length?
- Budget per person: hard limit or soft preference?
- Which auth method do we prefer?
- What monthly API budget is acceptable?
- Should the GitHub repo stay private (needs a paid plan for Pages) or become public?
- Custom domain, or the default `github.io` address?
