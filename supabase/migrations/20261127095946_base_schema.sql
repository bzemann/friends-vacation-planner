-- Base schema for Friends Vacation Planner: allowlist, profiles, trips,
-- trip_members, invites, helper functions, triggers, RLS and grants.
--
-- Security model: the `public` schema is the only schema exposed through the
-- Data API (see supabase/config.jsonc `api.schemas`). RLS is enabled on
-- every table in `public`, and grants are kept minimal (no blanket
-- `all`/`insert` on `trips` or `trip_members`: trip creation and joining a
-- trip happen through RPCs added in a later migration, not direct inserts).
-- Helper functions live in a separate `private` schema so they are never
-- reachable through the Data API even though PostgREST only exposes
-- `public`/`graphql_public` today.

-- Defensive: pgcrypto provides gen_random_bytes(), used for invite tokens.
-- Supabase projects normally already have this in the `extensions` schema.
create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- Schema for helper functions. Not listed in config.jsonc `api.schemas`, so
-- it is never exposed through the Data API regardless of grants.
-- ---------------------------------------------------------------------------
create schema if not exists private;

grant usage on schema private to authenticated;

-- ---------------------------------------------------------------------------
-- Default privileges: lock down objects created later by the migration-
-- owning role (postgres) in schema public, instead of inheriting Supabase's
-- permissive defaults (which otherwise auto-grant access to new tables,
-- sequences and functions). Every table/RPC created by a future migration
-- must grant access explicitly, the same way this migration does below.
--
-- Two separate statements for functions, both needed: the per-schema one
-- (`in schema public`) only removes the anon/authenticated grants that
-- Supabase adds by default for this schema; on its own it has no effect,
-- because Postgres' separate *global* default (no `in schema`) grants
-- EXECUTE to PUBLIC on every newly created function, PUBLIC includes
-- anon/authenticated (verified locally: without the global statement
-- below, a brand new function stayed callable by anon even with the
-- per-schema revoke in place). The global statement removes that PUBLIC
-- grant, so every future RPC must `grant execute ... to authenticated`
-- explicitly, same as the helper functions below do.
-- ---------------------------------------------------------------------------
alter default privileges for role postgres in schema public revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from anon, authenticated;
alter default privileges for role postgres in schema public revoke execute on functions from public, anon, authenticated;
alter default privileges for role postgres revoke execute on functions from public;

-- ---------------------------------------------------------------------------
-- allowlist: emails allowed to sign up without a trip invite. No grants and
-- no policies below: this table is not reachable through the Data API at
-- all, by anyone, authenticated or not. Only the service role (which
-- bypasses RLS and grants) or server-side logic reads it.
-- ---------------------------------------------------------------------------
create table public.allowlist (
  email text primary key check (email = lower(email) and position('@' in email) > 1),
  note text,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- profiles: one row per auth user, created automatically by the
-- handle_new_user trigger below. Holds only what the app needs beyond
-- auth.users (display name); everything else about a user lives elsewhere.
-- ---------------------------------------------------------------------------
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text check (
    display_name is null
    or char_length(display_name) between 1 and 80
  ),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- trips: one row per vacation-planning trip. created_by is kept for
-- reference ("who started this trip") but is not what grants ownership --
-- ownership is the 'owner' role in trip_members, so the creator can leave
-- the owner role to someone else without losing history here.
-- ---------------------------------------------------------------------------
create table public.trips (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 100),
  created_by uuid references public.profiles (id) on delete set null,
  currency text not null default 'CHF' check (currency ~ '^[A-Z]{3}$'),
  min_days int not null default 3 check (min_days >= 1),
  max_days int not null default 14 check (max_days <= 60),
  -- null means "all members must be free"; a number means "at least N of M".
  min_participants int check (
    min_participants is null
    or min_participants >= 2
  ),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint trips_max_days_ge_min_days check (max_days >= min_days)
);

-- ---------------------------------------------------------------------------
-- trip_members: who belongs to which trip, and with what role. Exactly one
-- 'owner' is enforced per trip by the partial unique index below, not just
-- by application logic / RPCs.
-- ---------------------------------------------------------------------------
create table public.trip_members (
  trip_id uuid not null references public.trips (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  role text not null default 'member' check (role in ('owner', 'member')),
  joined_at timestamptz not null default now(),
  primary key (trip_id, user_id)
);

create index trip_members_user_id_idx on public.trip_members (user_id);

-- Exactly one owner per trip: a second insert/update that would give a trip
-- a second 'owner' row violates this partial unique index.
create unique index trip_members_one_owner_idx on public.trip_members (trip_id)
where role = 'owner';

-- ---------------------------------------------------------------------------
-- invites: trip invite links (join?token=...), reusable until expiry or
-- revocation (usage rules decided in task 5). Tokens are random hex
-- strings, not guessable trip ids. created_by defaults to the caller so
-- RLS can check it without the client having to supply it.
-- ---------------------------------------------------------------------------
create table public.invites (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.trips (id) on delete cascade,
  token text not null unique default encode(extensions.gen_random_bytes(24), 'hex'),
  created_by uuid references public.profiles (id) on delete set null default auth.uid(),
  expires_at timestamptz not null default now() + interval '14 days',
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  constraint invites_expires_after_created check (expires_at > created_at),
  constraint invites_expires_within_30_days check (expires_at <= created_at + interval '30 days')
);

create index invites_trip_id_idx on public.invites (trip_id);

-- ---------------------------------------------------------------------------
-- Helper functions (schema private). `security definer` + `set search_path
-- = ''` + fully qualified names: these functions must not be hijackable by
-- changing the caller's search_path, and must be able to read
-- trip_members/trips regardless of the caller's own RLS visibility (that is
-- the whole point of using them inside policies).
-- Execute is revoked from public/anon and granted only to authenticated,
-- since anon has no legitimate use for them and should get a clean
-- "permission denied" rather than being able to probe trip membership.
-- ---------------------------------------------------------------------------

-- Is the current user a member (owner or plain member) of this trip?
create function private.is_trip_member(p_trip_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.trip_members
    where trip_id = p_trip_id
      and user_id = (select auth.uid())
  );
$$;

revoke execute on function private.is_trip_member (uuid) from public, anon;
grant execute on function private.is_trip_member (uuid) to authenticated;

-- Is the current user specifically the owner of this trip?
create function private.is_trip_owner(p_trip_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.trip_members
    where trip_id = p_trip_id
      and user_id = (select auth.uid())
      and role = 'owner'
  );
$$;

revoke execute on function private.is_trip_owner (uuid) from public, anon;
grant execute on function private.is_trip_owner (uuid) to authenticated;

-- Does the current user share at least one trip with p_user_id? Used so a
-- member can see the profiles of people they actually plan trips with,
-- without being able to see arbitrary other users' profiles.
create function private.shares_trip_with(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.trip_members a
    join public.trip_members b on a.trip_id = b.trip_id
    where a.user_id = (select auth.uid())
      and b.user_id = p_user_id
  );
$$;

revoke execute on function private.shares_trip_with (uuid) from public, anon;
grant execute on function private.shares_trip_with (uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Trigger: create a profile row automatically whenever a new auth user is
-- created (e.g. right after a magic-link signup). security definer because
-- the trigger fires as part of inserting into auth.users, a table the
-- inserting role does not own/have insert rights on public.profiles for
-- otherwise.
-- ---------------------------------------------------------------------------
create function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id)
  values (new.id)
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
after insert on auth.users
for each row
execute function private.handle_new_user ();

-- ---------------------------------------------------------------------------
-- Trigger: keep updated_at current on every update, instead of trusting
-- clients to set it. Runs as invoker (no security definer): it only ever
-- assigns to NEW, it never needs elevated access to read other tables.
-- ---------------------------------------------------------------------------
create function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger set_updated_at
before update on public.profiles
for each row
execute function private.set_updated_at ();

create trigger set_updated_at
before update on public.trips
for each row
execute function private.set_updated_at ();

-- ---------------------------------------------------------------------------
-- Row Level Security: on for every table. allowlist has no policies at all
-- (see note above), so RLS blocks every row for every non-bypassing role.
-- ---------------------------------------------------------------------------
alter table public.allowlist enable row level security;
alter table public.profiles enable row level security;
alter table public.trips enable row level security;
alter table public.trip_members enable row level security;
alter table public.invites enable row level security;

-- ---------------------------------------------------------------------------
-- Grants: start from nothing, then grant only what the app needs directly.
-- `anon` gets nothing on any of these tables; unauthenticated users only
-- ever interact through auth (signup/login) and, later, invite-token RPCs.
-- Trip creation and joining a trip are RPCs (security definer functions)
-- added in a later migration, which is why trips/trip_members have no
-- insert grant here.
-- ---------------------------------------------------------------------------
revoke all on public.allowlist from anon, authenticated;
revoke all on public.profiles from anon, authenticated;
revoke all on public.trips from anon, authenticated;
revoke all on public.trip_members from anon, authenticated;
revoke all on public.invites from anon, authenticated;

grant select, update (display_name) on public.profiles to authenticated;

grant select, delete on public.trips to authenticated;
grant update (name, currency, min_days, max_days, min_participants) on public.trips to authenticated;

grant select, delete on public.trip_members to authenticated;

grant select, delete on public.invites to authenticated;
grant insert (trip_id, expires_at) on public.invites to authenticated;
grant update (revoked_at) on public.invites to authenticated;

-- allowlist: no grants to anon or authenticated. Nothing further to add.

-- ---------------------------------------------------------------------------
-- Policies. All `to authenticated`; anon has no grants above so it never
-- reaches policy evaluation at all (permission denied first).
-- ---------------------------------------------------------------------------

-- profiles: see your own profile, or the profile of anyone you share a trip
-- with (so trip member lists can show names). Only update your own profile.
create policy profiles_select on public.profiles
for select to authenticated
using (
  id = (select auth.uid())
  or private.shares_trip_with (id)
);

create policy profiles_update on public.profiles
for update to authenticated
using (id = (select auth.uid()))
with check (id = (select auth.uid()));

-- trips: see trips you belong to; only the owner can rename/change settings
-- or delete the trip.
create policy trips_select on public.trips
for select to authenticated
using (private.is_trip_member (id));

create policy trips_update on public.trips
for update to authenticated
using (private.is_trip_owner (id))
with check (private.is_trip_owner (id));

create policy trips_delete on public.trips
for delete to authenticated
using (private.is_trip_owner (id));

-- trip_members: see the member list of trips you belong to. A member can
-- remove themself (leave), unless they are the owner; an owner can remove
-- any other member, but not themself (so a trip is never left ownerless).
create policy trip_members_select on public.trip_members
for select to authenticated
using (private.is_trip_member (trip_id));

create policy trip_members_delete on public.trip_members
for delete to authenticated
using (
  (
    user_id = (select auth.uid())
    and role <> 'owner'
  )
  or (
    private.is_trip_owner (trip_id)
    and user_id <> (select auth.uid())
  )
);

-- invites: only the trip owner can see, create, revoke (update) or delete
-- invites for their trip.
create policy invites_select on public.invites
for select to authenticated
using (private.is_trip_owner (trip_id));

create policy invites_insert on public.invites
for insert to authenticated
with check (
  private.is_trip_owner (trip_id)
  and created_by = (select auth.uid())
);

create policy invites_update on public.invites
for update to authenticated
using (private.is_trip_owner (trip_id))
with check (private.is_trip_owner (trip_id));

create policy invites_delete on public.invites
for delete to authenticated
using (private.is_trip_owner (trip_id));

-- allowlist: no policies. RLS is enabled with zero policies, so every role
-- other than a bypassing one (service_role/postgres) sees zero rows, and
-- combined with the grants above, authenticated/anon never even reach
-- policy evaluation.
