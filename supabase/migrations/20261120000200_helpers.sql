-- =====================================================================
-- Pomocné funkce, triggery, pohledy
-- =====================================================================

-- Nastavení -----------------------------------------------------------
create or replace function public.setting(p_key text)
returns jsonb language sql stable security definer set search_path = public as $$
  select value from public.app_settings where key = p_key
$$;

create or replace function public.setting_num(p_key text, p_default double precision)
returns double precision language sql stable security definer set search_path = public as $$
  select coalesce((select (value #>> '{}')::double precision from public.app_settings where key = p_key
                   and jsonb_typeof(value) = 'number'), p_default)
$$;

create or replace function public.setting_bool(p_key text, p_default boolean)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select (value #>> '{}')::boolean from public.app_settings where key = p_key
                   and jsonb_typeof(value) = 'boolean'), p_default)
$$;

-- Identita volajícího --------------------------------------------------
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select p.is_admin and not p.is_blocked from public.profiles p where p.id = auth.uid()), false)
$$;

-- Ověřený uživatel = přihlášený přes e-mail (ne anonymní relace)
create or replace function public.is_verified_user()
returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() is not null
     and coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) = false
     and coalesce((select u.email is not null and u.email <> '' from auth.users u where u.id = auth.uid()), false)
$$;

create or replace function public._require_user()
returns uuid language plpgsql stable security definer set search_path = public as $$
declare v uuid := auth.uid();
begin
  if v is null then
    raise exception 'not_authenticated' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.profiles where id = v and is_blocked) then
    raise exception 'blocked' using errcode = 'P0001';
  end if;
  return v;
end $$;

create or replace function public._require_admin()
returns uuid language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'forbidden' using errcode = 'P0001';
  end if;
  return auth.uid();
end $$;

-- Ochrana proti spamu: počet záznamů uživatele za časové okno
create or replace function public._rate_ok(p_table text, p_limit integer, p_window interval)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare n integer;
begin
  if public.is_admin() then return true; end if;
  if p_table not in ('reports', 'comments', 'supports', 'flags', 'photos') then
    raise exception 'bad_table';
  end if;
  execute format('select count(*) from public.%I where user_id = $1 and created_at > now() - $2', p_table)
    into n using auth.uid(), p_window;
  return n < p_limit;
end $$;

-- Jednoduchá heuristika spamu v textu (počet odkazů)
create or replace function public._looks_like_spam(p_text text)
returns boolean language sql immutable as $$
  select coalesce(
    (select count(*) from regexp_matches(coalesce(p_text, ''), '(https?://|www\.)', 'gi')) > 3
    or coalesce(p_text, '') ~* '(viagra|casino|crypto ?airdrop|porn)', false)
$$;

create or replace function public._clean(p_text text, p_max integer)
returns text language sql immutable as $$
  select nullif(left(btrim(regexp_replace(coalesce(p_text, ''), '[\u0000-\u0008\u000B\u000C\u000E-\u001F]', '', 'g')), p_max), '')
$$;

-- Metrická projekce pro výpočty (UTM 33N – Ivančice leží v pásmu 33)
create or replace function public._m(g extensions.geometry)
returns extensions.geometry language sql immutable parallel safe set search_path = public, extensions as $$
  select ST_Transform(g, 32633)
$$;

-- Místní část dle polohy -------------------------------------------------
create or replace function public._district_for(g extensions.geometry)
returns integer language sql stable security definer set search_path = public, extensions as $$
  with pt as (select ST_PointOnSurface(g) p)
  select coalesce(
    (select d.id from public.districts d, pt where d.boundary is not null and ST_Intersects(d.boundary, pt.p)
      order by d.sort_order limit 1),
    (select d.id from public.districts d, pt
      where not exists (select 1 from public.districts x where x.boundary is not null)
      order by ST_Distance(d.center::geography, pt.p::geography) limit 1),
    -- hranice jsou nahrány, ale bod leží mimo ně → nejbližší hranice do 1 km
    (select d.id from public.districts d, pt where d.boundary is not null
       and ST_DWithin(d.boundary::geography, pt.p::geography, 1000)
      order by ST_Distance(d.boundary::geography, pt.p::geography) limit 1)
  )
$$;

-- Triggery ---------------------------------------------------------------
create or replace function public._touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

drop trigger if exists trg_reports_touch on public.reports;
create trigger trg_reports_touch before update on public.reports
  for each row execute function public._touch_updated_at();
drop trigger if exists trg_profiles_touch on public.profiles;
create trigger trg_profiles_touch before update on public.profiles
  for each row execute function public._touch_updated_at();
drop trigger if exists trg_categories_touch on public.categories;
create trigger trg_categories_touch before update on public.categories
  for each row execute function public._touch_updated_at();

create or replace function public._reports_geom_derive()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
  if tg_op = 'INSERT' or new.geom is distinct from old.geom then
    new.length_m := case when new.geom_kind = 'line' then ST_Length(new.geom::geography) end;
    new.area_m2  := case when new.geom_kind = 'polygon' then ST_Area(new.geom::geography) end;
    new.district_id := public._district_for(new.geom);
  end if;
  return new;
end $$;

drop trigger if exists trg_reports_geom on public.reports;
create trigger trg_reports_geom before insert or update of geom on public.reports
  for each row execute function public._reports_geom_derive();

-- Profil se zakládá automaticky s novým uživatelem (i anonymním)
create or replace function public._handle_auth_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, is_admin)
  values (new.id, coalesce(new.email is not null and exists (select 1 from public.admin_emails a where a.email = lower(new.email)), false))
  on conflict (id) do update
    set is_admin = public.profiles.is_admin
                   or coalesce(new.email is not null and exists (select 1 from public.admin_emails a where a.email = lower(new.email)), false);
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public._handle_auth_user();
drop trigger if exists on_auth_user_email on auth.users;
create trigger on_auth_user_email after update of email on auth.users
  for each row when (new.email is distinct from old.email) execute function public._handle_auth_user();

-- Po smazání uživatele odstranit jeho hlasy (podpory nemají FK kvůli ukázkovým datům)
create or replace function public._handle_auth_user_deleted()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  delete from public.supports where user_id = old.id;
  return old;
end $$;
drop trigger if exists on_auth_user_deleted on auth.users;
create trigger on_auth_user_deleted after delete on auth.users
  for each row execute function public._handle_auth_user_deleted();

-- Veřejně viditelné podněty ----------------------------------------------
-- (nejsou skryté, nejsou sloučené do jiného, ukázková data jen pokud je zapnuto)
create or replace function public._visible_reports()
returns setof public.reports language sql stable security definer set search_path = public as $$
  select r.* from public.reports r
  where not r.is_hidden and r.merged_into is null
    and (not r.is_demo or public.setting_bool('show_demo', false))
$$;

-- Členové skupiny podnětu = autor + podporovatelé, včetně sloučených duplicit.
-- gid = id cílového (viditelného) podnětu.
create or replace view public.v_report_members as
  select coalesce(r.merged_into, r.id) as gid, r.author_key as person, true as is_author
    from public.reports r where not r.is_hidden
  union all
  select coalesce(r.merged_into, r.id) as gid, s.user_id as person, false as is_author
    from public.supports s join public.reports r on r.id = s.report_id where not r.is_hidden;

create or replace view public.v_report_people as
  select gid as report_id,
         count(distinct person)::int as people,                                   -- unikátní lidé celkem
         count(distinct person) filter (where is_author)::int as authors,         -- autoři zakreslení
         (count(distinct person) - count(distinct person) filter (where is_author))::int as supporters -- jen podpořili
  from public.v_report_members group by gid;

revoke all on public.v_report_members, public.v_report_people from anon, authenticated;

-- Funkce _require_* a interní pomocníky nevystavovat veřejnosti
revoke execute on function public._require_user(), public._require_admin(),
  public._rate_ok(text, integer, interval), public._visible_reports(),
  public._district_for(extensions.geometry) from public, anon, authenticated;

-- Nastavení čte veřejnost jen přes get_public_config (pouze veřejné klíče)
revoke execute on function public.setting(text), public.setting_num(text, double precision),
  public.setting_bool(text, boolean) from public, anon, authenticated;

-- Funkce používané v pravidlech RLS (např. úložiště fotografií) musí být spustitelné
-- i v projektech, kde se oprávnění k API nepřidělují automaticky.
grant usage on schema public to anon, authenticated;
grant execute on function public.is_admin(), public.is_verified_user() to anon, authenticated;
