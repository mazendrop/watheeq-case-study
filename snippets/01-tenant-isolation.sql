-- Tenant isolation in the database (illustrative, written for this case study).
--
-- Idea: every tenant-owned row carries the tenant key, and Postgres itself
-- filters rows by the signed-in user's memberships. Application code can
-- forget a WHERE clause; the policy cannot be forgotten.
--
-- Assumes a Supabase-style auth.uid() that returns the signed-in user's id.

create table firms (
  id   uuid primary key default gen_random_uuid(),
  name text not null
);

create table firm_members (
  firm_id uuid not null references firms on delete cascade,
  user_id   uuid not null,
  role      text not null check (role in ('owner', 'lawyer', 'trainee', 'staff', 'accountant')),
  primary key (firm_id, user_id)
);

-- Firms of the current user. SECURITY DEFINER so policies can call it without
-- recursing into firm_members' own policies; a fixed search_path so nobody
-- can shadow the tables it reads; STABLE because it only reads.
create function my_firm_ids() returns setof uuid
  language sql stable security definer set search_path = public as $$
  select firm_id from firm_members where user_id = auth.uid()
$$;

create function my_role_in(target uuid) returns text
  language sql stable security definer set search_path = public as $$
  select role from firm_members where firm_id = target and user_id = auth.uid()
$$;

create table matters (
  id         uuid primary key default gen_random_uuid(),
  firm_id  uuid not null references firms,
  title      text not null,
  status     text not null default 'open',
  created_at timestamptz not null default now()
);

-- The tenant key leads the index, so every query stays in one firm's slice.
create index matters_firm_status_idx on matters (firm_id, status, created_at desc);

alter table matters enable row level security;
alter table matters force row level security;  -- applies even to the table owner

-- `(select my_firm_ids())`: an uncorrelated sub-select runs once per statement
-- (an InitPlan in EXPLAIN), not once per row.
create policy matters_read on matters for select to authenticated
  using (firm_id in (select my_firm_ids()));

create policy matters_insert on matters for insert to authenticated
  with check (firm_id in (select my_firm_ids()));

-- USING decides which rows may be changed, WITH CHECK what they may become:
-- without it a member could move a matter into another firm.
create policy matters_update on matters for update to authenticated
  using (firm_id in (select my_firm_ids()))
  with check (firm_id in (select my_firm_ids()));

-- Roles live in the policy too: trainees cannot delete, whatever the UI shows.
create policy matters_delete on matters for delete to authenticated
  using (
    firm_id in (select my_firm_ids())
    and my_role_in(firm_id) in ('owner', 'lawyer')
  );

grant select, insert, update, delete on matters to authenticated;
