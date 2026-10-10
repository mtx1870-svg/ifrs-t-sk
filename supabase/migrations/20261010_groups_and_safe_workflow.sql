begin;

create extension if not exists pgcrypto;

create table if not exists public.study_groups (
  code text primary key,
  name text not null,
  locale text not null default 'sk' check (locale in ('sk', 'cs')),
  is_active boolean not null default true,
  is_archive boolean not null default false,
  created_at timestamptz not null default now()
);

insert into public.study_groups (code, name, locale, is_active, is_archive) values
  ('UA01', 'UA01', 'sk', true, false),
  ('UA02', 'UA02', 'sk', true, false),
  ('UA03', 'UA03', 'sk', true, false),
  ('UA04', 'UA04', 'sk', true, false),
  ('UA05', 'UA05', 'sk', true, false),
  ('AKT01', 'AKT01', 'sk', true, false),
  ('UAXX', 'UAXX – pôvodné záznamy', 'sk', true, true)
on conflict (code) do update set
  name = excluded.name,
  locale = excluded.locale,
  is_active = excluded.is_active,
  is_archive = excluded.is_archive;

alter table public.proposals add column if not exists group_id text;

-- Všetko, čo existovalo pred touto migráciou, patrí do archívnej skupiny UAXX.
update public.proposals set group_id = 'UAXX' where group_id is null;

alter table public.proposals alter column group_id set default 'UA01';
alter table public.proposals alter column group_id set not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'proposals_group_id_fkey'
  ) then
    alter table public.proposals
      add constraint proposals_group_id_fkey
      foreign key (group_id) references public.study_groups(code);
  end if;
end $$;

create index if not exists proposals_group_year_status_idx
  on public.proposals (group_id, year, status);
create index if not exists proposals_group_case_idx
  on public.proposals (group_id, year, case_number);

create table if not exists public.teacher_group_access (
  teacher_user_id uuid not null references auth.users(id) on delete cascade,
  group_id text not null references public.study_groups(code) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (teacher_user_id, group_id)
);

-- Existujúce účty a ich e-mailové adresy sa nemenia; dostanú prístup ku všetkým skupinám.
insert into public.teacher_group_access (teacher_user_id, group_id)
select t.user_id, g.code
from public.teacher_users t
cross join public.study_groups g
where lower(t.email) in (
  'tumpach@vutbr.cz',
  'lenka.uzikova@euba.sk',
  'zuzana.uzikova@euba.sk'
)
on conflict do nothing;

create table if not exists public.group_year_state (
  group_id text not null references public.study_groups(code) on delete cascade,
  year text not null check (year in ('20X1', '20X2', '20X3')),
  current_case_number integer,
  accepting_answers boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id),
  primary key (group_id, year)
);

insert into public.group_year_state (group_id, year, accepting_answers)
select g.code, y.year, false
from public.study_groups g
cross join (values ('20X1'), ('20X2'), ('20X3')) as y(year)
on conflict (group_id, year) do nothing;

create table if not exists public.group_cases (
  group_id text not null references public.study_groups(code) on delete cascade,
  year text not null check (year in ('20X1', '20X2', '20X3')),
  order_number integer not null check (order_number > 0),
  description text not null check (length(trim(description)) > 0),
  amount numeric not null default 0 check (amount >= 0),
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id),
  primary key (group_id, year, order_number)
);

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'proposals'
  ) then
    alter publication supabase_realtime add table public.proposals;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'group_year_state'
  ) then
    alter publication supabase_realtime add table public.group_year_state;
  end if;
end $$;

create or replace function public.is_group_teacher(p_group_id text)
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select exists (
    select 1
    from public.teacher_group_access a
    where a.teacher_user_id = auth.uid()
      and a.group_id = p_group_id
  );
$$;

alter table public.study_groups enable row level security;
alter table public.teacher_group_access enable row level security;
alter table public.group_year_state enable row level security;
alter table public.group_cases enable row level security;
alter table public.proposals enable row level security;

drop policy if exists study_groups_read on public.study_groups;
create policy study_groups_read on public.study_groups
  for select to authenticated using (is_active);

drop policy if exists teacher_access_read_own on public.teacher_group_access;
create policy teacher_access_read_own on public.teacher_group_access
  for select to authenticated using (teacher_user_id = auth.uid());

drop policy if exists group_year_state_read on public.group_year_state;
create policy group_year_state_read on public.group_year_state
  for select to authenticated using (true);

drop policy if exists group_cases_teacher_read on public.group_cases;
create policy group_cases_teacher_read on public.group_cases
  for select to authenticated using (public.is_group_teacher(group_id));

-- Pôvodné permissive pravidlá by mohli obísť izoláciu skupín.
do $$
declare p record;
begin
  for p in select policyname from pg_policies where schemaname = 'public' and tablename = 'proposals'
  loop
    execute format('drop policy if exists %I on public.proposals', p.policyname);
  end loop;
end $$;

create policy proposals_teacher_select on public.proposals
  for select to authenticated using (public.is_group_teacher(group_id));
create policy proposals_teacher_insert on public.proposals
  for insert to authenticated with check (public.is_group_teacher(group_id));
create policy proposals_teacher_update on public.proposals
  for update to authenticated
  using (public.is_group_teacher(group_id))
  with check (public.is_group_teacher(group_id));
create policy proposals_teacher_delete on public.proposals
  for delete to authenticated using (public.is_group_teacher(group_id));

-- Starú bezparametrovú funkciu odstránime, aby sa ňou nedalo obísť filtrovanie skupiny.
drop function if exists public.get_student_records();

create or replace function public.get_student_records(p_group_id text)
returns setof public.proposals
language sql
stable
security definer
set search_path = public, auth
as $$
  select p.*
  from public.proposals p
  where p.group_id = p_group_id
    and p_group_id <> 'UAXX'
    and (
      p.owner_id = auth.uid()
      or p.status in ('approved', 'case_prompt')
    );
$$;

create or replace function public.submit_student_proposal(
  p_group_id text,
  p_year text,
  p_student_name text,
  p_debit_account text,
  p_credit_account text,
  p_amount numeric,
  p_description text,
  p_case_number integer
)
returns text
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_state public.group_year_state%rowtype;
  v_id text := gen_random_uuid()::text;
begin
  if auth.uid() is null then raise exception 'Chýba používateľská relácia.'; end if;
  if p_group_id = 'UAXX' then raise exception 'Archívna skupina neprijíma odpovede.'; end if;
  if p_amount <= 0 then raise exception 'Suma musí byť kladná.'; end if;
  if nullif(trim(p_debit_account), '') is null or nullif(trim(p_credit_account), '') is null then
    raise exception 'Oba účty sú povinné.';
  end if;
  if p_debit_account = p_credit_account then raise exception 'Účty MD a D musia byť rozdielne.'; end if;

  select * into v_state
  from public.group_year_state
  where group_id = p_group_id and year = p_year
  for update;

  if not found or not v_state.accepting_answers then
    raise exception 'Vyučujúci momentálne neprijíma odpovede.';
  end if;
  if v_state.current_case_number is distinct from p_case_number then
    raise exception 'Zadanie sa medzitým zmenilo. Obnovte stránku.';
  end if;

  insert into public.proposals (
    id, group_id, year, student_name, debit_account, credit_account,
    amount, description, "timestamp", status, case_number, owner_id
  ) values (
    v_id, p_group_id, p_year, left(trim(p_student_name), 200),
    p_debit_account, p_credit_account, p_amount, left(trim(p_description), 2000),
    to_char(clock_timestamp(), 'HH24:MI:SS'), 'pending', p_case_number, auth.uid()
  );
  return v_id;
end;
$$;

create or replace function public.replace_group_cases(
  p_group_id text,
  p_year text,
  p_cases jsonb
)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if not public.is_group_teacher(p_group_id) then raise exception 'Nemáte prístup k skupine %.', p_group_id; end if;
  if p_group_id = 'UAXX' then raise exception 'Archívnu skupinu nemožno meniť.'; end if;
  if jsonb_typeof(p_cases) <> 'array' or jsonb_array_length(p_cases) = 0 then
    raise exception 'Zoznam prípadov je prázdny.';
  end if;

  delete from public.group_cases where group_id = p_group_id and year = p_year;
  insert into public.group_cases (group_id, year, order_number, description, amount, created_by)
  select p_group_id, p_year, x."order", trim(x.text), coalesce(x.amount, 0), auth.uid()
  from jsonb_to_recordset(p_cases) as x("order" integer, text text, amount numeric);
end;
$$;

create or replace function public.publish_group_case(
  p_group_id text,
  p_year text,
  p_case_number integer
)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare v_case public.group_cases%rowtype;
begin
  if not public.is_group_teacher(p_group_id) then raise exception 'Nemáte prístup k skupine %.', p_group_id; end if;
  if p_group_id = 'UAXX' then raise exception 'Archívnu skupinu nemožno meniť.'; end if;

  insert into public.group_year_state (group_id, year, current_case_number, accepting_answers, updated_by)
  values (p_group_id, p_year, p_case_number, false, auth.uid())
  on conflict (group_id, year) do update set
    current_case_number = excluded.current_case_number,
    accepting_answers = false,
    updated_at = now(),
    updated_by = auth.uid();

  if p_case_number is null then
    delete from public.proposals
    where id = 'case_prompt_' || p_group_id || '_' || p_year;
    return;
  end if;

  select * into strict v_case from public.group_cases
  where group_id = p_group_id and year = p_year and order_number = p_case_number;

  insert into public.proposals (
    id, group_id, year, student_name, debit_account, credit_account,
    amount, description, "timestamp", status, case_number, owner_id
  ) values (
    'case_prompt_' || p_group_id || '_' || p_year, p_group_id, p_year,
    '__CASE_PROMPT__', '', '', v_case.amount, v_case.description,
    clock_timestamp()::text, 'case_prompt', v_case.order_number, auth.uid()
  )
  on conflict (id) do update set
    group_id = excluded.group_id,
    amount = excluded.amount,
    description = excluded.description,
    "timestamp" = excluded."timestamp",
    case_number = excluded.case_number,
    owner_id = excluded.owner_id;
end;
$$;

create or replace function public.set_group_accepting_answers(
  p_group_id text,
  p_year text,
  p_accepting boolean
)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if not public.is_group_teacher(p_group_id) then raise exception 'Nemáte prístup k skupine %.', p_group_id; end if;
  if p_group_id = 'UAXX' and p_accepting then raise exception 'Archívna skupina neprijíma odpovede.'; end if;
  insert into public.group_year_state (group_id, year, accepting_answers, updated_by)
  values (p_group_id, p_year, p_accepting, auth.uid())
  on conflict (group_id, year) do update set
    accepting_answers = excluded.accepting_answers,
    updated_at = now(),
    updated_by = auth.uid();
end;
$$;

create or replace function public.review_student_proposal(p_proposal_id text, p_status text)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare v_group_id text;
begin
  if p_status not in ('approved', 'rejected') then raise exception 'Neplatný stav.'; end if;
  select group_id into v_group_id from public.proposals where id = p_proposal_id for update;
  if not found then raise exception 'Návrh neexistuje.'; end if;
  if not public.is_group_teacher(v_group_id) then raise exception 'Nemáte prístup k tejto skupine.'; end if;
  update public.proposals set status = p_status where id = p_proposal_id and status = 'pending';
  if not found then raise exception 'Návrh už bol spracovaný.'; end if;
end;
$$;

create or replace function public.approve_group_consensus(
  p_group_id text,
  p_year text,
  p_case_number integer,
  p_debit_account text,
  p_credit_account text,
  p_amount numeric,
  p_description text,
  p_label text
)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare v_count integer;
begin
  if not public.is_group_teacher(p_group_id) then raise exception 'Nemáte prístup k skupine %.', p_group_id; end if;
  perform 1 from public.group_year_state where group_id = p_group_id and year = p_year for update;

  select count(*) into v_count from public.proposals
  where group_id = p_group_id and year = p_year and status = 'pending'
    and case_number is not distinct from p_case_number;
  if v_count = 0 then raise exception 'Nie sú žiadne čakajúce návrhy pre tento prípad.'; end if;

  update public.proposals
  set status = case
    when debit_account = p_debit_account
      and credit_account = p_credit_account
      and abs(amount - p_amount) <= 1.0001 then 'consensus_match'
    else 'archived'
  end
  where group_id = p_group_id and year = p_year and status = 'pending'
    and case_number is not distinct from p_case_number;

  if not exists (
    select 1 from public.proposals
    where group_id = p_group_id and year = p_year and status = 'approved'
      and student_name like 'Konsenzus%'
      and case_number is not distinct from p_case_number
  ) then
    insert into public.proposals (
      id, group_id, year, student_name, debit_account, credit_account,
      amount, description, "timestamp", status, case_number, owner_id
    ) values (
      gen_random_uuid()::text, p_group_id, p_year, p_label,
      p_debit_account, p_credit_account, p_amount, p_description,
      to_char(clock_timestamp(), 'HH24:MI:SS'), 'approved', p_case_number, auth.uid()
    );
  end if;

  update public.group_year_state
  set accepting_answers = false, updated_at = now(), updated_by = auth.uid()
  where group_id = p_group_id and year = p_year;
end;
$$;

create or replace function public.reset_group_year(p_group_id text, p_year text)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if not public.is_group_teacher(p_group_id) then raise exception 'Nemáte prístup k skupine %.', p_group_id; end if;
  update public.proposals set status = 'archived_task'
  where group_id = p_group_id and year = p_year and status <> 'case_prompt';
  delete from public.proposals
  where group_id = p_group_id and year = p_year and status = 'case_prompt';
  update public.group_year_state
  set current_case_number = null, accepting_answers = false, updated_at = now(), updated_by = auth.uid()
  where group_id = p_group_id and year = p_year;
end;
$$;

revoke all on function public.get_student_records(text) from public;
revoke all on function public.is_group_teacher(text) from public;
revoke all on function public.submit_student_proposal(text,text,text,text,text,numeric,text,integer) from public;
revoke all on function public.replace_group_cases(text,text,jsonb) from public;
revoke all on function public.publish_group_case(text,text,integer) from public;
revoke all on function public.set_group_accepting_answers(text,text,boolean) from public;
revoke all on function public.review_student_proposal(text,text) from public;
revoke all on function public.approve_group_consensus(text,text,integer,text,text,numeric,text,text) from public;
revoke all on function public.reset_group_year(text,text) from public;

grant execute on function public.get_student_records(text) to authenticated;
grant execute on function public.is_group_teacher(text) to authenticated;
grant execute on function public.submit_student_proposal(text,text,text,text,text,numeric,text,integer) to authenticated;
grant execute on function public.replace_group_cases(text,text,jsonb) to authenticated;
grant execute on function public.publish_group_case(text,text,integer) to authenticated;
grant execute on function public.set_group_accepting_answers(text,text,boolean) to authenticated;
grant execute on function public.review_student_proposal(text,text) to authenticated;
grant execute on function public.approve_group_consensus(text,text,integer,text,text,numeric,text,text) to authenticated;
grant execute on function public.reset_group_year(text,text) to authenticated;

grant select on public.study_groups, public.teacher_group_access, public.group_year_state, public.group_cases to authenticated;
grant select, insert, update, delete on public.proposals to authenticated;

commit;

