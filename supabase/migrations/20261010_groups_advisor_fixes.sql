begin;

create index if not exists teacher_group_access_group_idx
  on public.teacher_group_access (group_id);
create index if not exists group_cases_created_by_idx
  on public.group_cases (created_by);
create index if not exists group_year_state_updated_by_idx
  on public.group_year_state (updated_by);

drop policy if exists teacher_access_read_own on public.teacher_group_access;
create policy teacher_access_read_own on public.teacher_group_access
  for select to authenticated
  using (teacher_user_id = (select auth.uid()));

commit;

