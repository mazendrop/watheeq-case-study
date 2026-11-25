-- An audit log that no code path can forget and nobody can edit
-- (illustrative, written for this case study).

create table audit_log (
  id         bigint generated always as identity primary key,
  firm_id  uuid,
  table_name text not null,
  row_id     text,
  action     text not null check (action in ('INSERT', 'UPDATE', 'DELETE')),
  actor      uuid default auth.uid(),
  at         timestamptz not null default now(),
  old_row    jsonb,
  new_row    jsonb
);

-- 1. Written by a trigger, so every change is captured, whichever code path made it.
create function audit_row_change() returns trigger
  language plpgsql security definer set search_path = public as $$
declare
  old_json jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  new_json jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
begin
  insert into audit_log (firm_id, table_name, row_id, action, old_row, new_row)
  values (
    (coalesce(new_json, old_json) ->> 'firm_id')::uuid,
    tg_table_name,
    coalesce(new_json, old_json) ->> 'id',
    tg_op,
    old_json,
    -- for updates keep only what changed
    case when tg_op = 'UPDATE'
      then (select jsonb_object_agg(key, value) from jsonb_each(new_json)
             where old_json -> key is distinct from value)
      else new_json end
  );
  return coalesce(new, old);
end $$;

-- 2. Append-only: edits and deletes are rejected, for everyone.
create function reject_change() returns trigger language plpgsql as $$
begin
  raise exception '% is append-only: % is not allowed', tg_table_name, tg_op
    using errcode = 'insufficient_privilege';
end $$;

create trigger audit_log_append_only
  before update or delete on audit_log
  for each row execute function reject_change();
create trigger audit_log_no_truncate
  before truncate on audit_log
  for each statement execute function reject_change();

-- 3. Attach to any table worth auditing.
create trigger matters_audit
  after insert or update or delete on matters
  for each row execute function audit_row_change();

-- Members read their own firm's history; nobody writes to it directly.
alter table audit_log enable row level security;
create policy audit_read on audit_log for select to authenticated
  using (firm_id in (select my_firm_ids()));
grant select on audit_log to authenticated;
