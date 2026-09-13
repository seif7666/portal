-- Default-deny for tables added later ("including the ones added after you've
-- moved on"). Any new table in public gets RLS enabled+forced the moment it is
-- created, so until someone writes a policy it returns nothing to anon or
-- authenticated. The isolation test suite (supabase/tests/rls_coverage.sql)
-- is the second line: it fails if a tenant table lacks a brand-scoped policy.

create or replace function private.enforce_rls_on_new_tables()
returns event_trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  obj record;
begin
  for obj in
    select * from pg_event_trigger_ddl_commands()
    where command_tag in ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      and schema_name = 'public'
      and object_type = 'table'
  loop
    execute format('alter table %s enable row level security', obj.object_identity);
    execute format('alter table %s force row level security', obj.object_identity);
    execute format('revoke all on %s from anon', obj.object_identity);
  end loop;
end
$$;

drop event trigger if exists enforce_rls_on_new_tables;
create event trigger enforce_rls_on_new_tables
  on ddl_command_end
  when tag in ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
  execute function private.enforce_rls_on_new_tables();

-- New tables in public should not be readable by anon by default either.
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on functions from anon;
alter default privileges in schema public revoke all on sequences from anon;
