-- RLS / grants / constraints coverage for the base schema.
--
-- Fixtures (fixed uuids for readability):
--   alice = 11111111-1111-1111-1111-111111111111  (owner of T1 and T3)
--   bob   = 22222222-2222-2222-2222-222222222222  (member of T1)
--   carol = 33333333-3333-3333-3333-333333333333  (owner of T2, unrelated to T1)
--   dave  = 44444444-4444-4444-4444-444444444444  (member of T1)
--   T1    = aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
--   T2    = bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb
--   T3    = eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee  (alice only; used for the
--           "owner deletes trip" test so T1 survives for the rest of the
--           suite)
--   invite_t1 = cccccccc-cccc-cccc-cccc-cccccccccccc (T1's invite, fixed id
--               so the revoke/delete tests at the end can target it
--               precisely even if other T1 invites exist by then)
--   invite_t2 = dddddddd-dddd-dddd-dddd-dddddddddddd (T2's invite)
--
-- Run as the superuser (postgres), which bypasses RLS and grants, so all
-- setup inserts below happen directly without needing the RPCs that will
-- be added in a later migration for real trip-creation/join flows.
begin;

select plan(58);

-- ---------------------------------------------------------------------------
-- Fixtures: 4 auth users (profiles are created by the
-- private.handle_new_user trigger, not inserted directly), 3 trips, their
-- members, and one invite each for T1 and T2.
-- ---------------------------------------------------------------------------
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at
) values
  ('00000000-0000-0000-0000-000000000000', '11111111-1111-1111-1111-111111111111', 'authenticated', 'authenticated', 'alice@example.com', 'x', now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '22222222-2222-2222-2222-222222222222', 'authenticated', 'authenticated', 'bob@example.com', 'x', now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '33333333-3333-3333-3333-333333333333', 'authenticated', 'authenticated', 'carol@example.com', 'x', now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '44444444-4444-4444-4444-444444444444', 'authenticated', 'authenticated', 'dave@example.com', 'x', now(), '{}', '{}', now(), now());

select is(
  (select count(*)::int from public.profiles where id in (
    '11111111-1111-1111-1111-111111111111',
    '22222222-2222-2222-2222-222222222222',
    '33333333-3333-3333-3333-333333333333',
    '44444444-4444-4444-4444-444444444444'
  )),
  4,
  'private.handle_new_user trigger created 4 profiles'
);

insert into public.trips (id, name, created_by)
values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'T1 Alps', '11111111-1111-1111-1111-111111111111'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'T2 Beach', '33333333-3333-3333-3333-333333333333'),
  ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', 'T3 Solo', '11111111-1111-1111-1111-111111111111');

insert into public.trip_members (trip_id, user_id, role)
values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '11111111-1111-1111-1111-111111111111', 'owner'),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '22222222-2222-2222-2222-222222222222', 'member'),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '44444444-4444-4444-4444-444444444444', 'member'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '33333333-3333-3333-3333-333333333333', 'owner'),
  ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', '11111111-1111-1111-1111-111111111111', 'owner');

insert into public.invites (id, trip_id, created_by)
values
  ('cccccccc-cccc-cccc-cccc-cccccccccccc', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '11111111-1111-1111-1111-111111111111'),
  ('dddddddd-dddd-dddd-dddd-dddddddddddd', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '33333333-3333-3333-3333-333333333333');

-- ---------------------------------------------------------------------------
-- Default privileges probe: a brand new function created (as postgres,
-- with no explicit grants) must not be executable by anon or authenticated
-- -- a regression test for the `alter default privileges` statements in
-- the migration. Dropped automatically by this file's rollback.
-- ---------------------------------------------------------------------------
create function public.zz_default_priv_probe()
returns int
language sql
as $$ select 1; $$;

select is(
  has_function_privilege('anon', 'public.zz_default_priv_probe()', 'execute'),
  false,
  'default privileges: anon cannot execute a freshly created function'
);
select is(
  has_function_privilege('authenticated', 'public.zz_default_priv_probe()', 'execute'),
  false,
  'default privileges: authenticated cannot execute a freshly created function'
);

-- ---------------------------------------------------------------------------
-- anon: no grants on any of the 5 tables, so every select/insert/update is
-- a flat permission-denied, never reaching RLS policy evaluation.
-- ---------------------------------------------------------------------------
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);

select throws_ok($$ select count(*) from public.profiles $$, '42501', null, 'anon: select profiles is denied');
select throws_ok($$ select count(*) from public.trips $$, '42501', null, 'anon: select trips is denied');
select throws_ok($$ select count(*) from public.trip_members $$, '42501', null, 'anon: select trip_members is denied');
select throws_ok($$ select count(*) from public.invites $$, '42501', null, 'anon: select invites is denied');
select throws_ok($$ select count(*) from public.allowlist $$, '42501', null, 'anon: select allowlist is denied');

-- (h) anon insert/update on trips and invites.
select throws_ok($$ insert into public.trips (name) values ('Anon trip') $$, '42501', null, 'anon: insert into trips is denied');
select throws_ok($$ update public.trips set name = 'x' $$, '42501', null, 'anon: update trips is denied');
select throws_ok(
  $$ insert into public.invites (trip_id, expires_at) values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', now() + interval '1 day') $$,
  '42501',
  null,
  'anon: insert into invites is denied'
);
select throws_ok($$ update public.invites set revoked_at = now() $$, '42501', null, 'anon: update invites is denied');

-- ---------------------------------------------------------------------------
-- bob: member (not owner) of T1, no relation to T2.
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true);

select is(
  (select count(*)::int from public.trips where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  1,
  'bob: sees T1'
);
select is(
  (select count(*)::int from public.trips where id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'),
  0,
  'bob: does not see T2'
);
select is(
  (select count(*)::int from public.trip_members where trip_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  3,
  'bob: sees all 3 T1 members (alice, bob, dave)'
);
select is(
  (select count(*)::int from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  1,
  'bob: sees alice''s profile (shares T1)'
);
select is(
  (select count(*)::int from public.profiles where id = '33333333-3333-3333-3333-333333333333'),
  0,
  'bob: does not see carol''s profile'
);
select is(
  (select count(*)::int from public.invites where trip_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  0,
  'bob: cannot see T1 invites (not owner)'
);
select throws_ok(
  $$ insert into public.invites (trip_id, expires_at) values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', now() + interval '1 day') $$,
  '42501',
  null,
  'bob: cannot insert a T1 invite (not owner)'
);

update public.trips set name = 'Hacked by bob' where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
select is(
  (select name from public.trips where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  'T1 Alps',
  'bob: cannot rename T1 (name unchanged)'
);

delete from public.trips where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
select is(
  (select count(*)::int from public.trips where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  1,
  'bob: cannot delete T1 (still exists)'
);

-- Any authenticated user (bob here): no insert/update grant on
-- trip_members, no insert grant on trips, no grant at all on allowlist.
select throws_ok(
  $$ insert into public.trip_members (trip_id, user_id) values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '22222222-2222-2222-2222-222222222222') $$,
  '42501',
  null,
  'authenticated: insert into trip_members is denied (no grant)'
);
select throws_ok(
  $$ insert into public.trips (name) values ('Rogue trip') $$,
  '42501',
  null,
  'authenticated: insert into trips is denied (no grant)'
);
select throws_ok(
  $$ select count(*) from public.allowlist $$,
  '42501',
  null,
  'authenticated: select on allowlist is denied (no grant)'
);

-- (a) bob cannot promote himself to owner (no update grant on trip_members
-- at all, regardless of RLS).
select throws_ok(
  $$ update public.trip_members set role = 'owner' where trip_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' and user_id = '22222222-2222-2222-2222-222222222222' $$,
  '42501',
  null,
  'bob: cannot update trip_members.role to owner (no grant)'
);

-- (b) bob (non-owner) cannot remove alice (the owner) or dave (another
-- plain member): both deletes match 0 rows under RLS, no error.
delete from public.trip_members
where trip_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  and user_id = '11111111-1111-1111-1111-111111111111';
select is(
  (select count(*)::int from public.trip_members where trip_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' and user_id = '11111111-1111-1111-1111-111111111111'),
  1,
  'bob: cannot remove alice (owner) from T1 (row stays)'
);
delete from public.trip_members
where trip_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  and user_id = '44444444-4444-4444-4444-444444444444';
select is(
  (select count(*)::int from public.trip_members where trip_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' and user_id = '44444444-4444-4444-4444-444444444444'),
  1,
  'bob: cannot remove dave (another member) from T1 (row stays)'
);

-- (e) alice cannot update another member's display_name, even though she
-- can see bob's profile (both are still in T1 at this point: this proves
-- the profiles_update policy's own id = auth.uid() check, not merely that
-- the row happens to be invisible).
reset role;
update public.profiles set display_name = 'Bob B (fixture)' where id = '22222222-2222-2222-2222-222222222222';

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
update public.profiles set display_name = 'Hacked by alice' where id = '22222222-2222-2222-2222-222222222222';

reset role;
select is(
  (select display_name from public.profiles where id = '22222222-2222-2222-2222-222222222222'),
  'Bob B (fixture)',
  'alice: cannot update bob''s display_name even though she can see his profile'
);

-- bob can leave T1 (delete own, non-owner membership).
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true);
delete from public.trip_members
where trip_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  and user_id = '22222222-2222-2222-2222-222222222222';

reset role;
select is(
  (select count(*)::int from public.trip_members
    where trip_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      and user_id = '22222222-2222-2222-2222-222222222222'),
  0,
  'bob: left T1 (membership row gone)'
);

-- (i) once bob has left, he no longer sees T1 or alice's profile.
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true);
select is(
  (select count(*)::int from public.trips where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  0,
  'bob: no longer sees T1 after leaving'
);
select is(
  (select count(*)::int from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  0,
  'bob: no longer sees alice''s profile after leaving T1'
);

-- ---------------------------------------------------------------------------
-- alice: owner of T1 and T3, no relation to T2.
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);

select is(
  (select count(*)::int from public.invites where trip_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  1,
  'alice: sees the T1 invite (owner)'
);
select lives_ok(
  $$ insert into public.invites (trip_id, expires_at) values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', now() + interval '1 day') $$,
  'alice: can insert a T1 invite (owner)'
);

update public.trips set name = 'T1 Alps (renamed)' where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
select is(
  (select name from public.trips where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  'T1 Alps (renamed)',
  'alice: can rename T1 (owner)'
);

select is(
  (select count(*)::int from public.invites where trip_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'),
  0,
  'alice: cannot see T2 invites (not owner there)'
);
select throws_ok(
  $$ insert into public.invites (trip_id, expires_at) values ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', now() + interval '1 day') $$,
  '42501',
  null,
  'alice: cannot insert a T2 invite (not owner there)'
);

-- (c) alice (owner) can remove dave from T1.
delete from public.trip_members
where trip_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  and user_id = '44444444-4444-4444-4444-444444444444';
select is(
  (select count(*)::int from public.trip_members where trip_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' and user_id = '44444444-4444-4444-4444-444444444444'),
  0,
  'alice: removed dave from T1 (owner)'
);

-- alice (owner) cannot delete her own owner membership.
delete from public.trip_members
where trip_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  and user_id = '11111111-1111-1111-1111-111111111111';
select is(
  (select count(*)::int from public.trip_members
    where trip_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      and user_id = '11111111-1111-1111-1111-111111111111'),
  1,
  'alice: cannot leave T1 as the owner (membership row still present)'
);

-- (f) column-grant checks on invites: created_by, token and trip_id are
-- not in the granted insert/update column lists, regardless of RLS.
select throws_ok(
  $$ insert into public.invites (trip_id, expires_at, created_by) values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', now() + interval '1 day', '11111111-1111-1111-1111-111111111111') $$,
  '42501',
  null,
  'alice: cannot insert an invite with explicit created_by (no column grant)'
);
select throws_ok(
  $$ insert into public.invites (trip_id, expires_at, token) values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', now() + interval '1 day', 'deadbeef') $$,
  '42501',
  null,
  'alice: cannot insert an invite with explicit token (no column grant)'
);
select throws_ok(
  $$ update public.invites set trip_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' where id = 'cccccccc-cccc-cccc-cccc-cccccccccccc' $$,
  '42501',
  null,
  'alice: cannot update invites.trip_id (no column grant)'
);

-- (e) profiles: own display_name update works (the "another user's does
-- not" case was already covered earlier, while alice could still see
-- bob's profile); updating profiles.id is denied outright (no column
-- grant).
update public.profiles set display_name = 'Alice A' where id = '11111111-1111-1111-1111-111111111111';
select is(
  (select display_name from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  'Alice A',
  'alice: can update her own display_name'
);
select throws_ok(
  $$ update public.profiles set id = '99999999-9999-9999-9999-999999999999' where id = '11111111-1111-1111-1111-111111111111' $$,
  '42501',
  null,
  'alice: cannot update profiles.id (no column grant)'
);

-- (g) alice (owner) can revoke and delete T1's invite; the same ops on
-- T2's invite affect 0 rows.
update public.invites set revoked_at = now() where id = 'cccccccc-cccc-cccc-cccc-cccccccccccc';
select is(
  (select revoked_at is not null from public.invites where id = 'cccccccc-cccc-cccc-cccc-cccccccccccc'),
  true,
  'alice: revoked the T1 invite (owner)'
);
delete from public.invites where id = 'cccccccc-cccc-cccc-cccc-cccccccccccc';
select is(
  (select count(*)::int from public.invites where id = 'cccccccc-cccc-cccc-cccc-cccccccccccc'),
  0,
  'alice: deleted the T1 invite (owner)'
);
update public.invites set revoked_at = now() where id = 'dddddddd-dddd-dddd-dddd-dddddddddddd';
delete from public.invites where id = 'dddddddd-dddd-dddd-dddd-dddddddddddd';

reset role;
select is(
  (select revoked_at from public.invites where id = 'dddddddd-dddd-dddd-dddd-dddddddddddd'),
  null,
  'alice: cannot revoke T2''s invite (unchanged)'
);
select is(
  (select count(*)::int from public.invites where id = 'dddddddd-dddd-dddd-dddd-dddddddddddd'),
  1,
  'alice: cannot delete T2''s invite (still exists)'
);

-- (d) alice (owner) can delete a whole trip. Uses T3 (alice-only), so T1
-- is left intact for the rest of the suite.
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
delete from public.trips where id = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';
select is(
  (select count(*)::int from public.trips where id = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'),
  0,
  'alice: deleted T3 (owner)'
);

-- ---------------------------------------------------------------------------
-- carol: owner of T2, no relation to T1 at all.
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true);

select is(
  (select count(*)::int from public.trips where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  0,
  'carol: cannot see T1'
);
select is(
  (select count(*)::int from public.trip_members where trip_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  0,
  'carol: cannot see T1 members'
);
select is(
  (select count(*)::int from public.invites where trip_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  0,
  'carol: cannot see T1 invites'
);

-- ---------------------------------------------------------------------------
-- Check constraints (role-independent; run as postgres, which bypasses
-- grants/RLS but not CHECK/UNIQUE constraints).
-- ---------------------------------------------------------------------------
reset role;

select throws_ok(
  $$ insert into public.trips (name, min_days, max_days) values ('Bad trip', 10, 5) $$,
  '23514',
  null,
  'trips: max_days < min_days is rejected'
);
select throws_ok(
  $$ insert into public.trips (name, min_participants) values ('Bad trip 2', 1) $$,
  '23514',
  null,
  'trips: min_participants = 1 is rejected'
);
select throws_ok(
  $$ insert into public.trips (name, max_days) values ('Bad trip 3', 61) $$,
  '23514',
  null,
  'trips: max_days = 61 is rejected'
);
select throws_ok(
  $$ insert into public.trips (name, min_days) values ('Bad trip 4', 0) $$,
  '23514',
  null,
  'trips: min_days = 0 is rejected'
);
select throws_ok(
  $$ insert into public.invites (trip_id, expires_at) values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', now() + interval '60 days') $$,
  '23514',
  null,
  'invites: expires_at more than 30 days out is rejected'
);
-- Uses carol, who has no existing trip_members row for T1 at all (she is
-- only ever a member of T2), so the primary key (trip_id, user_id) cannot
-- be what triggers this -- only the partial unique index on (trip_id)
-- where role = 'owner' can.
select throws_ok(
  $$ insert into public.trip_members (trip_id, user_id, role) values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '33333333-3333-3333-3333-333333333333', 'owner') $$,
  '23505',
  'duplicate key value violates unique constraint "trip_members_one_owner_idx"',
  'trip_members: a second owner on the same trip is rejected (unique index)'
);

-- Boundary: expires_at exactly 30 days after created_at is accepted.
-- created_at defaults to now(), and now() returns the same value for the
-- whole transaction, so this is an exact (not approximate) boundary check.
select lives_ok(
  $$ insert into public.invites (trip_id, expires_at) values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', now() + interval '30 days') $$,
  'invites: expires_at exactly 30 days out is accepted'
);

select * from finish();

rollback;
