# Deployment Guide

## Overview

This app runs on three services:

1. **Browser app**: a static Next.js export served by GitHub Pages at https://bzemann.github.io/friends-vacation-planner/
2. **Backend**: Supabase (database, authentication, Edge Functions, secrets)
3. **LLM calls**: Anthropic API (called only from Supabase Edge Functions)

| Value | Public or Secret | Where it lives |
|---|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | Public | GitHub repository variable + local `.env` |
| `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | Public | GitHub repository variable + local `.env` |
| Database password | Secret | Your password manager only |
| Supabase CLI access token | Secret | Stored locally by `supabase login` |
| `ANTHROPIC_API_KEY` (prod) | Secret | Supabase Edge Function secrets only |
| `ANTHROPIC_API_KEY` (dev) | Secret | `supabase/functions/.env` (gitignored) |

**Rule:** Never paste any secret into a chat with Claude or agents, into a repository file, or into a GitHub secret/variable.

---

## Create the Supabase Project

1. Go to https://supabase.com and log in with your account.
2. Click **"New project"**.
3. Enter project name: **`friends-vacation-planner`**
4. Choose region: **Central EU (Zurich) / `eu-central-2`**
5. Generate a strong database password (20+ characters, mix of uppercase, lowercase, numbers, symbols). **Store it in your password manager immediately.** You will not see it again.
6. Click **"Create new project"** and wait for the database to initialize (1–2 minutes).

**Where to find key values:**
- **Project ref** (e.g., `abc123def456`): Project Settings → General, also visible in the URL `https://supabase.com/project/[ref]/…`
- **Project URL** (e.g., `https://abc123def456.supabase.co`): Project Settings → Data API
- **Publishable key** (`sb_publishable_…`): Project Settings → API Keys

**Free plan note:** Projects pause automatically after about 1 week of inactivity. You can resume them anytime in the dashboard without losing data.

---

## Connect the CLI and Apply Migrations

From the project root directory:

```bash
npx supabase login
```

A browser window opens. Authenticate with your Supabase account. The CLI stores an access token locally (not in the repo).

```bash
npx supabase link --project-ref <project-ref>
```

Replace `<project-ref>` with your project ref (e.g., `abc123def456`). The CLI prompts you for the database password. Paste it from your password manager.

```bash
npx supabase db push
```

This command applies all migrations in `supabase/migrations/` to the remote database. Migrations are pushed by hand on purpose; an automated migration workflow may be added later as its own roadmap task (not planned yet).

**Verify everything is in sync:**

```bash
npx supabase migration list
```

Output should show local and remote migrations with matching checksums.

---

## Maintain the Allowlist

Only email addresses on the allowlist (or people with a valid trip invite from roadmap tasks 4 and 5) can sign up for the app.

To add an email:

1. Go to your Supabase project dashboard.
2. Click **"SQL Editor"** (left sidebar).
3. Click **"New query"**.
4. Paste this, replacing `<email>` and `<who>` with the actual values:

   ```sql
   insert into public.allowlist (email, note) values (lower('<email>'), '<who>');
   ```

   Example:
   ```sql
   insert into public.allowlist (email, note) values (lower('alice@example.com'), 'Alice, trip organizer');
   ```

5. Click **"Run"** (or Ctrl+Enter).

To remove an email:

```sql
delete from public.allowlist where email = lower('<email>');
```

**Note:** The allowlist table is not readable through the app itself; only the dashboard SQL editor (which runs as the `postgres` role and bypasses RLS) can access it.

---

## Anthropic: Two Workspaces, Two Keys

The app uses two separate API key workspaces to keep development and production budgets isolated. Each key is set immediately after it is created.

### Production Workspace and Key

#### Create workspace

1. Go to https://console.anthropic.com (the Anthropic API Console, separate from claude.ai).
2. Sign in. If prompted, verify your email.
3. Click **Settings** → **Workspaces** → **Create a new workspace**.
4. Name it: **`friends-vacation-planner`** (this will be the production workspace).
5. Create it.

#### Set spending limit

1. In the Workspaces section, click on the workspace name.
2. Click **Limits**.
3. Set a monthly spending limit: about USD 27 (equivalent to CHF 25).

The spend limit caps any accidental overage.

#### Create and set API key

1. Click **Settings** → **API keys**.
2. Click **Create key**.
3. Name: **`vacation-planner-prod`**
4. Workspace: **`friends-vacation-planner`**
5. Click **Create**.
6. **Copy the key immediately** (it is shown only once). If you lose it, just create a new key in this workspace.

**Now immediately add this key to Supabase:**

Go to your Supabase project dashboard.
- Click **Project Settings** (bottom of left sidebar) → **Edge Functions** (or **Settings → Edge Functions**, depending on your dashboard version).
- Click the **"Secrets"** button (or **"Add secret"** if none exist yet).
- Enter:
  - **Name:** `ANTHROPIC_API_KEY`
  - **Value:** Paste the prod key you just created
- Click **"Add secret"** (or **"Save"**).

**Why through the dashboard and not the terminal:** Commands are saved in plain text in your shell history (`~/.zsh_history`). The dashboard does not expose the key to your terminal.

**Verify:** From the project root, run:

```bash
npx supabase secrets list
```

Output shows the secret name and a digest (not the actual value), confirming it was set.

### Development Workspace and Key

#### Create workspace

1. Go to https://console.anthropic.com.
2. Click **Settings** → **Workspaces** → **Create a new workspace**.
3. Name it: **`friends-vacation-planner-dev`** (for local development).
4. Create it.

#### Set spending limit

1. In the Workspaces section, click on the workspace name.
2. Click **Limits**.
3. Set a monthly spending limit: about USD 5 (equivalent to CHF 5).

#### Create and set API key

1. Click **Settings** → **API keys**.
2. Click **Create key**.
3. Name: **`vacation-planner-dev`**
4. Workspace: **`friends-vacation-planner-dev`**
5. Click **Create**.
6. **Copy the key immediately** (it is shown only once). If you lose it, just create a new key in this workspace.

**Now immediately add this key locally:**

1. From the project root, copy the example file:

   ```bash
   cp supabase/functions/.env.example supabase/functions/.env
   ```

2. Open `supabase/functions/.env` in your editor (VS Code, etc.).
3. Find the line that says `ANTHROPIC_API_KEY=` (it may be blank or commented).
4. Paste the dev key you just created after the `=`. The file should look like:

   ```
   ANTHROPIC_API_KEY=<your-dev-key>
   ```

5. Save the file.

**Verify it is ignored by Git:**

```bash
git check-ignore -v supabase/functions/.env
```

Output should print a `.gitignore` rule (e.g., `.gitignore:24:.env	supabase/functions/.env`), confirming the file is ignored.

**Important:** Never use the prod key locally. Never put the dev key in Supabase.

| Workspace | Key name | Spend limit | Where the key lives |
|---|---|---|---|
| `friends-vacation-planner` | `vacation-planner-prod` | ~CHF 25/month | Supabase Edge Function secrets |
| `friends-vacation-planner-dev` | `vacation-planner-dev` | ~CHF 5/month | Local `supabase/functions/.env` |

### If a Key Leaks or Is Compromised

1. Go to **console.anthropic.com** → **Settings** → **API keys**.
2. Find the key and click the trash icon to revoke it.
3. Create a new key in the same workspace. Keys are shown only once; you cannot retrieve a lost key.
4. Update it in the appropriate place (Supabase secrets for prod, local `supabase/functions/.env` for dev).
5. The spend limit protects you from unexpected charges while you rotate the key.

**Note:** The API key is first needed in roadmap task 14. Until then, everything runs using mock providers and does not call Claude.

---

## GitHub Repository Variables

These are public values that will be used by the build (GitHub Actions) starting in roadmap task 4. They differ from secrets because both values are public by design and appear in the browser code.

From the project root:

```bash
gh variable set NEXT_PUBLIC_SUPABASE_URL --body "https://<project-ref>.supabase.co"
```

Replace `<project-ref>` with your Supabase project ref (e.g., `abc123def456`).

```bash
gh variable set NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY --body "<sb_publishable_...>"
```

Replace `<sb_publishable_...>` with your publishable key from Project Settings → API Keys.

**Verify:**

```bash
gh variable list
```

Both variables should appear in the list.

---

## GitHub Pages and Deployment

The website is deployed automatically whenever you merge a pull request into the `main` branch.

**How it works:**
- The `.github/workflows/deploy.yml` workflow runs on every push to `main`.
- It builds the app with the GitHub Pages base path, uploads the static files, and deploys them to GitHub Pages.
- The live site is at https://bzemann.github.io/friends-vacation-planner/

**Watch a deployment:**

```bash
gh run watch
```

This command streams the latest workflow run. Press `q` to exit.

**Manual redeploy (if needed):**

```bash
gh workflow run deploy.yml
```

**Branch protection:**
The `main` branch requires the `ci` status check to pass before merging. This ensures tests, linting, and type checking all succeed.

**Troubleshooting deployments:**

If a deployment fails:

```bash
gh run view --log-failed
```

This shows the logs of the failed step. Common causes:
- **"Missing … from lock file":** The `package-lock.json` is out of sync. Regenerate it locally with `npm install` (requires npm 11.19 or newer; check with `npm -v`), then commit and push.
- **Other build errors:** Check the full log for details.

**If GitHub Pages is ever disabled:**
1. Go to your repository on GitHub.
2. Click **Settings** → **Pages** (left sidebar).
3. Under **Source**, choose **GitHub Actions**.

---

## Local Development

**Requirements:**
- Node 24 LTS (see `.nvmrc`; Node 25 also works)
- npm 11.19 or newer
- Docker Desktop (running in the background for the local database)

**Initial setup:**

```bash
npm install
```

**Start the local database:**

```bash
npm run db:start
```

This starts Supabase in Docker and prints the local URL and publishable key. These are demo keys; they are public and safe to use locally.

**Reset the database** (rebuild from migrations and seed data):

```bash
npm run db:reset
```

**Run database tests** (RLS tests with pgTAP):

```bash
npm run db:test
```

**Stop the local database:**

```bash
npm run db:stop
```

**Start the development server:**

```bash
npm run dev
```

The app opens at http://localhost:3000. Changes to files automatically reload.

**Build for production** (creates a static export in `out/`):

```bash
npm run build
```

To build exactly as it appears on GitHub Pages (with the base path), set the environment variable:

```bash
NEXT_PUBLIC_BASE_PATH=/friends-vacation-planner npm run build
```

**Run tests:**

```bash
npm test
```

Runs Vitest once on all `lib/**/*.test.ts` files. For continuous watch mode:

```bash
npm run test:watch
```

**Run all checks** (linting, type checking, formatting):

```bash
npm run check
```

This runs the same checks as the Claude Code post-edit hook (`scripts/check.sh`).

---

## Checklist Summary

**One-time manual steps:**

- [ ] Create Supabase project (`friends-vacation-planner`, region Central EU, store password in password manager)
- [ ] Run `npx supabase login` and authenticate in browser
- [ ] Run `npx supabase link --project-ref <project-ref>` and enter database password
- [ ] Run `npx supabase db push` to apply migrations
- [ ] Verify: `npx supabase migration list` shows local and remote in sync
- [ ] Add yourself to the allowlist via SQL Editor: `insert into public.allowlist (email, note) values (lower('<your-email>'), '<your-name>');`
- [ ] Create Anthropic workspace `friends-vacation-planner` (prod) and set spend limit
- [ ] Create Anthropic API key `vacation-planner-prod` in prod workspace
- [ ] Add prod key to Supabase Edge Function secrets (immediately after creating the key)
- [ ] Create Anthropic workspace `friends-vacation-planner-dev` (dev) and set spend limit
- [ ] Create Anthropic API key `vacation-planner-dev` in dev workspace
- [ ] Add dev key to `supabase/functions/.env` (immediately after creating the key)
- [ ] Verify dev key is gitignored: `git check-ignore -v supabase/functions/.env`
- [ ] Set GitHub variable `NEXT_PUBLIC_SUPABASE_URL` with `gh variable set …`
- [ ] Set GitHub variable `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` with `gh variable set …`
- [ ] Verify variables: `gh variable list`

**After deployment:**

- [ ] Watch the first deployment: `gh run watch`
- [ ] Verify the live site at https://bzemann.github.io/friends-vacation-planner/

**Local development:**

- [ ] Install dependencies: `npm install`
- [ ] Start local database: `npm run db:start`
- [ ] (Optional) Run `npm run db:reset` to rebuild with seed data
- [ ] Start dev server: `npm run dev`
- [ ] Run checks: `npm run check`
