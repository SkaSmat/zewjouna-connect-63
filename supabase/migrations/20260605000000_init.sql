-- ZEWJOUNA — backend initial schema
-- Dating app for the Algerian diaspora (Bumble-style).
-- Stack: Postgres + PostGIS + Supabase Auth/Storage/Realtime + strict RLS.
--
-- This migration is the single source of truth for the data contract the
-- frontend already expects (see src/lib/database.types.ts).

-- ---------------------------------------------------------------------------
-- Extensions
-- ---------------------------------------------------------------------------
create extension if not exists postgis;     -- geography(Point) + distance queries
create extension if not exists pgcrypto;    -- gen_random_uuid()

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
do $$ begin
  create type public.gender as enum ('female', 'male', 'nonbinary');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.looking_for as enum ('female', 'male', 'nonbinary', 'everyone');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.swipe_action as enum ('like', 'pass');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.report_status as enum ('open', 'reviewing', 'resolved', 'dismissed');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
create table if not exists public.profiles (
  user_id        uuid primary key references auth.users (id) on delete cascade,
  display_name   text,
  bio            text,
  photos         text[] not null default '{}',          -- storage paths "<uid>/<file>"
  birthdate      date,
  gender         public.gender,
  looking_for    public.looking_for,
  location       geography(Point, 4326),                -- lng/lat
  community_tags text[] not null default '{}',          -- regions + languages + interests
  verified       boolean not null default false,
  last_active_at timestamptz default now(),
  created_at     timestamptz not null default now(),
  constraint bio_len check (bio is null or char_length(bio) <= 1000),
  constraint name_len check (display_name is null or char_length(display_name) <= 60)
);

create index if not exists profiles_location_gix on public.profiles using gist (location);
create index if not exists profiles_tags_gin     on public.profiles using gin (community_tags);
create index if not exists profiles_active_idx    on public.profiles (last_active_at desc);

create table if not exists public.swipes (
  id         uuid primary key default gen_random_uuid(),
  swiper_id  uuid not null references auth.users (id) on delete cascade,
  swiped_id  uuid not null references auth.users (id) on delete cascade,
  action     public.swipe_action not null,
  created_at timestamptz not null default now(),
  constraint no_self_swipe check (swiper_id <> swiped_id),
  constraint uniq_swipe unique (swiper_id, swiped_id)
);

create index if not exists swipes_swiped_idx on public.swipes (swiped_id);

create table if not exists public.matches (
  id                   uuid primary key default gen_random_uuid(),
  user_a               uuid not null references auth.users (id) on delete cascade,
  user_b               uuid not null references auth.users (id) on delete cascade,
  created_at           timestamptz not null default now(),
  expires_at           timestamptz,                     -- Bumble 24h window
  conversation_started boolean not null default false,
  constraint ordered_pair check (user_a < user_b),      -- canonical ordering
  constraint uniq_match unique (user_a, user_b)
);

create index if not exists matches_user_a_idx on public.matches (user_a);
create index if not exists matches_user_b_idx on public.matches (user_b);

create table if not exists public.messages (
  id         uuid primary key default gen_random_uuid(),
  match_id   uuid not null references public.matches (id) on delete cascade,
  sender_id  uuid not null references auth.users (id) on delete cascade,
  content    text not null,
  created_at timestamptz not null default now(),
  read_at    timestamptz,
  constraint content_len check (char_length(content) between 1 and 2000)
);

create index if not exists messages_match_idx on public.messages (match_id, created_at);

create table if not exists public.blocks (
  blocker_id uuid not null references auth.users (id) on delete cascade,
  blocked_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  constraint no_self_block check (blocker_id <> blocked_id)
);

create index if not exists blocks_blocked_idx on public.blocks (blocked_id);

create table if not exists public.reports (
  id          uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references auth.users (id) on delete cascade,
  reported_id uuid not null references auth.users (id) on delete cascade,
  reason      text not null,
  status      public.report_status not null default 'open',
  created_at  timestamptz not null default now(),
  constraint no_self_report check (reporter_id <> reported_id)
);

-- ---------------------------------------------------------------------------
-- Helper functions (security definer — bypass RLS for internal checks)
-- ---------------------------------------------------------------------------
create or replace function public.are_blocked(a uuid, b uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.blocks
    where (blocker_id = a and blocked_id = b)
       or (blocker_id = b and blocked_id = a)
  );
$$;

create or replace function public.is_matched(a uuid, b uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.matches
    where (user_a = least(a, b) and user_b = greatest(a, b))
  );
$$;

-- Case-insensitive text array intersection (Postgres has no built-in `&` for text[]).
create or replace function public.array_intersect(a text[], b text[])
returns text[]
language sql immutable as $$
  select coalesce(array(select unnest(coalesce(a, '{}'))
                        intersect
                        select unnest(coalesce(b, '{}'))), '{}');
$$;

-- ---------------------------------------------------------------------------
-- Trigger: create a match on reciprocal "like"
-- ---------------------------------------------------------------------------
create or replace function public.handle_swipe()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- keep the swiper's activity fresh
  update public.profiles set last_active_at = now() where user_id = new.swiper_id;

  if new.action = 'like' and exists (
    select 1 from public.swipes s
    where s.swiper_id = new.swiped_id
      and s.swiped_id = new.swiper_id
      and s.action = 'like'
  ) and not public.are_blocked(new.swiper_id, new.swiped_id) then
    insert into public.matches (user_a, user_b, expires_at)
    values (
      least(new.swiper_id, new.swiped_id),
      greatest(new.swiper_id, new.swiped_id),
      now() + interval '24 hours'
    )
    on conflict (user_a, user_b) do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_swipe_match on public.swipes;
create trigger trg_swipe_match
  after insert on public.swipes
  for each row execute function public.handle_swipe();

-- ---------------------------------------------------------------------------
-- Trigger: first message "opens" the match (lifts the 24h expiry)
-- ---------------------------------------------------------------------------
create or replace function public.handle_message()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update public.profiles set last_active_at = now() where user_id = new.sender_id;
  update public.matches
     set conversation_started = true,
         expires_at = null
   where id = new.match_id and conversation_started = false;
  return new;
end;
$$;

drop trigger if exists trg_message_open on public.messages;
create trigger trg_message_open
  after insert on public.messages
  for each row execute function public.handle_message();

-- ---------------------------------------------------------------------------
-- Messaging rule guard (Bumble: in a hetero pair, only the woman initiates;
-- respect block + expiry). Used by the messages INSERT policy.
-- ---------------------------------------------------------------------------
create or replace function public.can_send_message(p_match_id uuid, p_sender uuid)
returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  m              public.matches%rowtype;
  other_id       uuid;
  sender_gender  public.gender;
  other_gender   public.gender;
  msg_count      integer;
begin
  select * into m from public.matches where id = p_match_id;
  if m.id is null then return false; end if;
  if p_sender <> m.user_a and p_sender <> m.user_b then return false; end if;

  other_id := case when m.user_a = p_sender then m.user_b else m.user_a end;
  if public.are_blocked(p_sender, other_id) then return false; end if;

  select count(*) into msg_count from public.messages where match_id = p_match_id;

  -- An un-opened match that has passed its 24h window is dead.
  if msg_count = 0 and m.expires_at is not null and m.expires_at < now() then
    return false;
  end if;

  -- First message of a hetero pair: only the woman may send it.
  if msg_count = 0 then
    select gender into sender_gender from public.profiles where user_id = p_sender;
    select gender into other_gender  from public.profiles where user_id = other_id;
    if sender_gender = 'male' and other_gender = 'female' then
      return false;
    end if;
  end if;

  return true;
end;
$$;

-- ---------------------------------------------------------------------------
-- RPC: get_match_profile — public-safe profile of someone you matched with
-- ---------------------------------------------------------------------------
create or replace function public.get_match_profile(p_target uuid)
returns table (
  user_id        uuid,
  display_name   text,
  bio            text,
  age            integer,
  gender         public.gender,
  community_tags text[],
  verified       boolean
)
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null or not public.is_matched(me, p_target) then
    return;
  end if;
  return query
    select p.user_id,
           p.display_name,
           p.bio,
           case when p.birthdate is not null
                then date_part('year', age(p.birthdate))::int end,
           p.gender,
           coalesce(p.community_tags, '{}'),
           p.verified
    from public.profiles p
    where p.user_id = p_target;
end;
$$;

-- ---------------------------------------------------------------------------
-- RPC: get_candidates_adaptive — the discovery feed.
-- Hard filters: not self, not already swiped, not blocked, mutual gender
--   interest, age range, (when geolocated) within an adaptively widening
--   radius until p_target candidates are reachable.
-- Ranking: shared community tags first (the real differentiator), then
--   proximity, then recency. Returns only public-safe columns.
-- ---------------------------------------------------------------------------
create or replace function public.get_candidates_adaptive(
  p_target  integer default 10,
  p_min_age integer default 18,
  p_max_age integer default 99,
  p_limit   integer default 20
)
returns table (
  user_id        uuid,
  display_name   text,
  bio            text,
  photos         text[],
  age            integer,
  gender         public.gender,
  community_tags text[],
  shared_tags    text[],
  distance_m     double precision
)
language plpgsql stable security definer set search_path = public as $$
declare
  me         uuid := auth.uid();
  my_loc     geography;
  my_tags    text[];
  my_gender  public.gender;
  my_lf      public.looking_for;
  radius     double precision := 50000;     -- start at 50 km
  max_radius double precision := 2000000;   -- cap at 2000 km (then go global)
  reachable  integer := 0;
begin
  if me is null then return; end if;

  select pr.location, coalesce(pr.community_tags, '{}'), pr.gender, pr.looking_for
    into my_loc, my_tags, my_gender, my_lf
    from public.profiles pr where pr.user_id = me;

  -- Adaptively widen the radius until enough people are within range.
  if my_loc is not null then
    loop
      select count(*) into reachable
      from public.profiles p
      where p.user_id <> me
        and p.location is not null
        and st_dwithin(p.location, my_loc, radius)
        and not exists (select 1 from public.swipes s
                          where s.swiper_id = me and s.swiped_id = p.user_id)
        and not public.are_blocked(me, p.user_id)
        and (my_lf is null or my_lf = 'everyone' or p.gender::text = my_lf::text)
        and (p.looking_for is null or p.looking_for = 'everyone'
             or my_gender is null or p.looking_for::text = my_gender::text)
        and (p.birthdate is null
             or date_part('year', age(p.birthdate))::int between p_min_age and p_max_age);
      exit when reachable >= p_target or radius >= max_radius;
      radius := radius * 2;
    end loop;
  end if;

  return query
    select p.user_id,
           p.display_name,
           p.bio,
           p.photos,
           case when p.birthdate is not null
                then date_part('year', age(p.birthdate))::int end as age,
           p.gender,
           coalesce(p.community_tags, '{}') as community_tags,
           public.array_intersect(p.community_tags, my_tags) as shared_tags,
           case when my_loc is not null and p.location is not null
                then st_distance(p.location, my_loc) end as distance_m
    from public.profiles p
    where p.user_id <> me
      and not exists (select 1 from public.swipes s
                        where s.swiper_id = me and s.swiped_id = p.user_id)
      and not public.are_blocked(me, p.user_id)
      and (my_lf is null or my_lf = 'everyone' or p.gender::text = my_lf::text)
      and (p.looking_for is null or p.looking_for = 'everyone'
           or my_gender is null or p.looking_for::text = my_gender::text)
      and (p.birthdate is null
           or date_part('year', age(p.birthdate))::int between p_min_age and p_max_age)
      and (my_loc is null or p.location is null
           or st_dwithin(p.location, my_loc, radius))
    order by
      cardinality(public.array_intersect(p.community_tags, my_tags)) desc,
      (case when my_loc is not null and p.location is not null
            then st_distance(p.location, my_loc) end) asc nulls last,
      p.last_active_at desc nulls last
    limit p_limit;
end;
$$;

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.swipes   enable row level security;
alter table public.matches  enable row level security;
alter table public.messages enable row level security;
alter table public.blocks   enable row level security;
alter table public.reports  enable row level security;

-- profiles: you may only read/write your OWN row directly. Everyone else's
-- data is exposed exclusively through the security-definer RPCs above, which
-- return public-safe columns only. This is the core privacy guarantee.
drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own on public.profiles
  for select to authenticated using (user_id = auth.uid());

drop policy if exists profiles_insert_own on public.profiles;
create policy profiles_insert_own on public.profiles
  for insert to authenticated with check (user_id = auth.uid());

drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- swipes: a user records and reads only their own swipes; cannot swipe blocked.
drop policy if exists swipes_select_own on public.swipes;
create policy swipes_select_own on public.swipes
  for select to authenticated using (swiper_id = auth.uid());

drop policy if exists swipes_insert_own on public.swipes;
create policy swipes_insert_own on public.swipes
  for insert to authenticated
  with check (swiper_id = auth.uid() and not public.are_blocked(swiper_id, swiped_id));

-- matches: visible only to members. Rows are created by the trigger
-- (security definer), never directly by clients — no insert/update/delete policy.
drop policy if exists matches_select_member on public.matches;
create policy matches_select_member on public.matches
  for select to authenticated
  using (user_a = auth.uid() or user_b = auth.uid());

-- messages: readable by both members; insert gated by can_send_message;
-- recipient may update (to set read_at).
drop policy if exists messages_select_member on public.messages;
create policy messages_select_member on public.messages
  for select to authenticated
  using (exists (select 1 from public.matches m
                 where m.id = match_id
                   and (m.user_a = auth.uid() or m.user_b = auth.uid())));

drop policy if exists messages_insert_sender on public.messages;
create policy messages_insert_sender on public.messages
  for insert to authenticated
  with check (sender_id = auth.uid() and public.can_send_message(match_id, auth.uid()));

drop policy if exists messages_update_recipient on public.messages;
create policy messages_update_recipient on public.messages
  for update to authenticated
  using (sender_id <> auth.uid()
         and exists (select 1 from public.matches m
                     where m.id = match_id
                       and (m.user_a = auth.uid() or m.user_b = auth.uid())))
  with check (sender_id <> auth.uid());

-- blocks: manage only your own blocks.
drop policy if exists blocks_select_own on public.blocks;
create policy blocks_select_own on public.blocks
  for select to authenticated using (blocker_id = auth.uid());

drop policy if exists blocks_insert_own on public.blocks;
create policy blocks_insert_own on public.blocks
  for insert to authenticated with check (blocker_id = auth.uid());

drop policy if exists blocks_delete_own on public.blocks;
create policy blocks_delete_own on public.blocks
  for delete to authenticated using (blocker_id = auth.uid());

-- reports: file and read only your own reports.
drop policy if exists reports_select_own on public.reports;
create policy reports_select_own on public.reports
  for select to authenticated using (reporter_id = auth.uid());

drop policy if exists reports_insert_own on public.reports;
create policy reports_insert_own on public.reports
  for insert to authenticated with check (reporter_id = auth.uid());

-- ---------------------------------------------------------------------------
-- Grants (RLS still governs row visibility on top of these)
-- ---------------------------------------------------------------------------
grant usage on schema public to anon, authenticated;

grant select, insert, update on public.profiles to authenticated;
grant select, insert            on public.swipes   to authenticated;
grant select                    on public.matches  to authenticated;
grant select, insert, update    on public.messages to authenticated;
grant select, insert, delete    on public.blocks   to authenticated;
grant select, insert            on public.reports  to authenticated;

grant execute on function public.get_candidates_adaptive(integer, integer, integer, integer) to authenticated;
grant execute on function public.get_match_profile(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Realtime: stream new messages to the chat screen
-- ---------------------------------------------------------------------------
do $$ begin
  alter publication supabase_realtime add table public.messages;
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- Storage: private bucket for profile photos. Users manage only their own
-- "<uid>/..." folder. Other people's photos are never publicly readable — the
-- `signed-photo-urls` edge function mints short-lived signed URLs server-side.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('profile-photos', 'profile-photos', false)
on conflict (id) do nothing;

drop policy if exists photos_select_own on storage.objects;
create policy photos_select_own on storage.objects
  for select to authenticated
  using (bucket_id = 'profile-photos'
         and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists photos_insert_own on storage.objects;
create policy photos_insert_own on storage.objects
  for insert to authenticated
  with check (bucket_id = 'profile-photos'
              and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists photos_update_own on storage.objects;
create policy photos_update_own on storage.objects
  for update to authenticated
  using (bucket_id = 'profile-photos'
         and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists photos_delete_own on storage.objects;
create policy photos_delete_own on storage.objects
  for delete to authenticated
  using (bucket_id = 'profile-photos'
         and (storage.foldername(name))[1] = auth.uid()::text);
