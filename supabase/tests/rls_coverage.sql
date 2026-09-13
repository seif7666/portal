-- Returns one row per isolation violation. Zero rows = the guarantee holds.
-- Run by tests/isolation/rls-coverage.test.ts. Written as a plain query so it
-- also runs by hand:  psql "$SUPABASE_DB_URL" -f supabase/tests/rls_coverage.sql
--
-- Tables that are allowed to have no brand_id column (they ARE the tenancy).
with not_tenant_scoped(table_name) as (
  values ('brands')
),
tables as (
  select c.oid, c.relname as table_name, c.relrowsecurity, c.relforcerowsecurity
  from pg_class c
  where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p')
),
violations as (
  -- 1. RLS must be enabled and forced on every public table
  select table_name, 'rls_not_enabled' as problem from tables where not relrowsecurity
  union all
  select table_name, 'rls_not_forced' from tables where not relforcerowsecurity

  -- 2. every table carries brand_id (unless it is the tenancy table itself)
  union all
  select t.table_name, 'missing_brand_id_column'
  from tables t
  where t.table_name not in (select table_name from not_tenant_scoped)
    and not exists (
      select 1 from pg_attribute a
      where a.attrelid = t.oid and a.attname = 'brand_id' and not a.attisdropped and a.attnotnull
    )

  -- 3. a SELECT policy scoped through private.current_brand_ids() must exist
  union all
  select t.table_name, 'missing_brand_scoped_select_policy'
  from tables t
  where not exists (
    select 1 from pg_policies p
    where p.schemaname = 'public' and p.tablename = t.table_name
      and p.cmd in ('SELECT', 'ALL')
      and p.qual like '%current_brand_ids()%'
  )

  -- 4. no policy may be open to anon/public, and no policy may be unconditional
  union all
  select p.tablename, 'policy_open_to_anon_or_public:' || p.policyname
  from pg_policies p
  where p.schemaname = 'public' and (p.roles && array['anon', 'public']::name[])
  union all
  select p.tablename, 'policy_not_brand_scoped:' || p.policyname
  from pg_policies p
  where p.schemaname = 'public' and p.permissive = 'PERMISSIVE'
    and coalesce(p.qual, '') not like '%current_brand_ids()%'
    and coalesce(p.with_check, '') not like '%current_brand_ids()%'

  -- 5. anon holds no table privileges in public
  union all
  select t.table_name, 'anon_has_privilege'
  from tables t
  where has_table_privilege('anon', t.oid, 'select,insert,update,delete')

  -- 6. authenticated may only read tables directly; writes go through RPCs
  union all
  select t.table_name, 'authenticated_can_write_directly'
  from tables t
  where has_table_privilege('authenticated', t.oid, 'insert,update,delete')

  -- 7. views must run with the caller's rights, or they bypass RLS
  union all
  select c.relname, 'view_not_security_invoker'
  from pg_class c
  where c.relnamespace = 'public'::regnamespace and c.relkind in ('v', 'm')
    and not coalesce(c.reloptions @> array['security_invoker=true'], false)

  -- 8. SECURITY DEFINER functions exposed via the API must check membership
  union all
  select p.proname, 'security_definer_rpc_without_membership_check'
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.prosecdef
    -- trigger functions cannot be invoked through the API
    and p.prorettype not in ('trigger'::regtype, 'event_trigger'::regtype)
    and p.prosrc not like '%private.assert_member(%'
    -- internals for the edge functions: callable by the service role only
    and not (p.prosrc like '%private.assert_service_role()%'
             and not has_function_privilege('authenticated', p.oid, 'execute')
             and not has_function_privilege('anon', p.oid, 'execute'))
    and p.proname not in (select unnest(array[
      -- public entry points that are intentionally callable without a session
      -- and do their own checks (documented where defined)
      'shared_report_open'   -- public by design: token + password checked inside
    ]))
)
select table_name as object, problem from violations order by 1, 2;
