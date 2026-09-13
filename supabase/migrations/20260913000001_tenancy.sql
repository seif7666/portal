-- Tenancy foundation: brands, the membership allowlist, and the helpers every
-- RLS policy in this project goes through.
--
-- THE DATA-ISOLATION GUARANTEE LIVES HERE: private.current_brand_ids() is the
-- only source of "which brands may this caller see". Every tenant table's
-- policy is written as  brand_id in (select private.current_brand_ids()).

create extension if not exists pgcrypto with schema extensions;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- brands
-- ---------------------------------------------------------------------------
create table public.brands (
  id          uuid primary key default gen_random_uuid(),
  slug        text not null unique check (slug ~ '^[a-z][a-z0-9-]{1,40}$'),
  code        text not null unique check (code ~ '^[A-Z]{2,20}$'),  -- brand_code in exports
  name        text not null check (length(name) between 1 and 100),
  country     char(2) not null,
  timezone    text not null,
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- memberships: the allowlist. Exactly who may sign in, and to what.
-- Keyed by email so the same person works whether they arrive via password
-- or Google (Supabase links identities that share a verified email).
-- ---------------------------------------------------------------------------
create table public.memberships (
  id          uuid primary key default gen_random_uuid(),
  brand_id    uuid not null references public.brands(id) on delete restrict,
  email       text not null unique              -- one brand per person
              check (email = lower(btrim(email)) and email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  role        text not null check (role in ('owner', 'analyst')),
  created_at  timestamptz not null default now()
);
create index on public.memberships (brand_id);

-- ---------------------------------------------------------------------------
-- Helpers (SECURITY DEFINER, in a schema PostgREST does not expose)
-- ---------------------------------------------------------------------------

-- Email of the calling user, only if Supabase has verified it.
-- Read from auth.users (not the JWT claim) so a stale or forged claim can't
-- widen access.
create or replace function private.current_email()
returns text
language sql stable security definer
set search_path = ''
as $$
  select lower(u.email)
  from auth.users u
  where u.id = auth.uid()
    and u.email_confirmed_at is not null
    and u.deleted_at is null
    and coalesce(u.banned_until, '-infinity') < now()
$$;

create or replace function private.current_brand_ids()
returns setof uuid
language sql stable security definer
set search_path = ''
as $$
  select m.brand_id
  from public.memberships m
  where m.email = private.current_email()
$$;

create or replace function private.is_owner(p_brand_id uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.memberships m
    where m.email = private.current_email()
      and m.brand_id = p_brand_id
      and m.role = 'owner'
  )
$$;

-- Raise unless the caller belongs to the brand (optionally as owner).
create or replace function private.assert_member(p_brand_id uuid, p_require_owner boolean default false)
returns void
language plpgsql stable security definer
set search_path = ''
as $$
begin
  if p_brand_id is null or not exists (
    select 1 from public.memberships m
    where m.email = private.current_email()
      and m.brand_id = p_brand_id
      and (not p_require_owner or m.role = 'owner')
  ) then
    -- Same error whether the brand exists or not: no enumeration.
    raise exception 'not permitted' using errcode = '42501';
  end if;
end
$$;

grant usage on schema private to authenticated;
grant execute on function private.current_email(), private.current_brand_ids(),
  private.is_owner(uuid), private.assert_member(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.brands enable row level security;
alter table public.brands force row level security;
alter table public.memberships enable row level security;
alter table public.memberships force row level security;

create policy brands_select on public.brands
  for select to authenticated
  using (id in (select private.current_brand_ids()));

-- A user sees their own brand's team (owner + analyst), nothing else.
create policy memberships_select on public.memberships
  for select to authenticated
  using (brand_id in (select private.current_brand_ids()));

-- No insert/update/delete policies: memberships are managed by migrations /
-- service role only.

revoke all on public.brands, public.memberships from anon;
revoke insert, update, delete, truncate on public.brands, public.memberships from authenticated;
grant select on public.brands, public.memberships to authenticated;

-- ---------------------------------------------------------------------------
-- "Who am I" for the SPA: brand + role for the signed-in user.
-- ---------------------------------------------------------------------------
create or replace function public.my_membership()
returns table (brand_id uuid, brand_slug text, brand_name text, brand_timezone text, role text, email text)
language sql stable security invoker
set search_path = ''
as $$
  select b.id, b.slug, b.name, b.timezone, m.role, m.email
  from public.memberships m
  join public.brands b on b.id = m.brand_id
  where m.email = private.current_email()
$$;
revoke execute on function public.my_membership() from public, anon;
grant execute on function public.my_membership() to authenticated;

-- ---------------------------------------------------------------------------
-- Seed brands (memberships seeded separately once emails are final)
-- ---------------------------------------------------------------------------
insert into public.brands (slug, code, name, country, timezone) values
  ('kilele',    'KILELE',    'Kilele Rides',       'KE', 'Africa/Nairobi'),
  ('karoo',     'KAROO',     'Karoo Coaches',      'ZA', 'Africa/Johannesburg'),
  ('marrakech', 'MARRAKECH', 'Marrakech Express',  'MA', 'Africa/Casablanca');
