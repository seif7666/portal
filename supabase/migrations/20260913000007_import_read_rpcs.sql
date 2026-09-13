-- Read-side helpers for the Imports screens. SECURITY INVOKER: they run as the
-- caller, so RLS on import_runs / import_issues does the brand scoping.

-- "What didn't load and why", grouped: one line per (severity, code, field).
create or replace function public.import_issue_summary(p_run_id uuid)
returns table (severity text, code text, field text, n bigint, example_message text, first_row int)
language sql stable security invoker set search_path = '' as $$
  select i.severity, i.code, i.field, count(*), min(i.message), min(i.row_number)
  from public.import_issues i
  where i.run_id = p_run_id
  group by i.severity, i.code, i.field
  order by case i.severity when 'error' then 0 else 1 end, count(*) desc
$$;

revoke execute on function public.import_issue_summary(uuid) from public, anon;
grant execute on function public.import_issue_summary(uuid) to authenticated;
