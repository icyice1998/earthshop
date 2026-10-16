-- Run once in YOUR Supabase project: SQL Editor -> New query -> Run
create table if not exists public.app_state (
  id int primary key,
  data jsonb,
  rev int not null default 0,
  updated_by text,
  updated_at timestamptz default now()
);

alter table public.app_state enable row level security;

-- only logged-in users may read; writes go through save_state only
drop policy if exists "auth read" on public.app_state;
create policy "auth read" on public.app_state
  for select to authenticated using (true);

-- returns new rev, or -1 when expected_rev is stale (conflict)
create or replace function public.save_state(expected_rev int, new_data jsonb, who text)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare r int;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  insert into app_state (id, data, rev) values (1, '{}'::jsonb, 0)
    on conflict (id) do nothing;
  update app_state
     set data = new_data, rev = rev + 1, updated_by = who, updated_at = now()
   where id = 1 and rev = expected_rev
   returning rev into r;
  if r is null then return -1; end if;
  return r;
end $$;

revoke all on function public.save_state(int, jsonb, text) from public, anon;
grant execute on function public.save_state(int, jsonb, text) to authenticated;
