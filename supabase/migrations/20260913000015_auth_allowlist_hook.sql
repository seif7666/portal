-- "Someone who isn't one of the six gets in nowhere."
--
-- Supabase Auth calls this before creating ANY user (email sign-up, Google,
-- admin API). Emails not on the memberships allowlist are refused, so a
-- stranger cannot even obtain a session. RLS remains the second line: a user
-- who somehow exists without a membership still sees nothing.
--
-- Enabled in Auth settings as: pg-functions://postgres/private/hook_before_user_created

create or replace function private.hook_before_user_created(event jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email text := lower(btrim(coalesce(event->'user'->>'email', '')));
begin
  if v_email <> '' and exists (select 1 from public.memberships m where m.email = v_email) then
    return '{}'::jsonb;
  end if;
  return jsonb_build_object('error', jsonb_build_object(
    'http_code', 403,
    'message', 'This account is not invited to the Campaign Portal.'));
end
$$;

revoke execute on function private.hook_before_user_created(jsonb) from public, anon, authenticated;
grant usage on schema private to supabase_auth_admin;
grant execute on function private.hook_before_user_created(jsonb) to supabase_auth_admin;
