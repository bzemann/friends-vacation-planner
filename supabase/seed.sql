-- Local/dev seed data. Only test fixtures: no real emails anywhere.
insert into public.allowlist (email, note)
values
  ('alice@example.com', 'local test user'),
  ('bob@example.com', 'local test user');
