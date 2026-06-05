-- ZEWJOUNA — jeu de profils de test (DEV uniquement, ne pas exécuter en prod).
--
-- Crée 12 utilisateurs fictifs (connectables : mot de passe « zewjouna123 ») et
-- leurs profils géolocalisés avec des tags communautaires, pour pouvoir tester
-- la découverte / le swipe immédiatement.
--
-- À coller dans le SQL Editor du dashboard Supabase, APRÈS la migration.
-- Ré-exécutable sans risque (idempotent via ON CONFLICT).
--
-- NB : on utilise une table de travail normale (et non TEMPORARY) car le SQL
-- Editor de Supabase exécute les instructions dans des sessions distinctes —
-- une table temporaire n'y survivrait pas d'une instruction à l'autre.

drop table if exists public._zew_seed;

create table public._zew_seed (
  id          uuid,
  email       text,
  display_name text,
  gender      public.gender,
  looking_for public.looking_for,
  age         int,
  lng         double precision,
  lat         double precision,
  tags        text[],
  bio         text
);

insert into public._zew_seed values
  ('a0000000-0000-4000-8000-000000000001','yasmine.test@zewjouna.app','Yasmine','female','male',28, 2.3522,48.8566, array['Kabylie','Français','Cuisine'],            'Kabyle de Paris, je cuisine mieux que ta mère (presque).'),
  ('a0000000-0000-4000-8000-000000000002','karim.test@zewjouna.app','Karim','male','female',31, 2.3490,48.8600, array['Oranais','Arabe','Sport'],                 'Oranais, fan de foot et de bons couscous du dimanche.'),
  ('a0000000-0000-4000-8000-000000000003','lina.test@zewjouna.app','Lina','female','everyone',26, 4.8357,45.7640, array['Algérois','Français','Voyages'],          'Lyonnaise dans l’âme, alger­oise de cœur. Toujours partante pour un voyage.'),
  ('a0000000-0000-4000-8000-000000000004','mehdi.test@zewjouna.app','Mehdi','male','female',30, 2.3600,48.8500, array['Kabylie','Kabyle','Musique'],               'Guitariste amateur, je chante du Idir sous la douche.'),
  ('a0000000-0000-4000-8000-000000000005','sofia.test@zewjouna.app','Sofia','female','male',27, 5.3698,43.2965, array['Constantinois','Arabe','Art'],              'Marseillaise, passionnée d’art et de zalabia.'),
  ('a0000000-0000-4000-8000-000000000006','amine.test@zewjouna.app','Amine','male','female',29, 2.3400,48.8700, array['Kabylie','Français','Cinéma'],              'Cinéphile, je débats pendant des heures sur le meilleur film algérien.'),
  ('a0000000-0000-4000-8000-000000000007','nadia.test@zewjouna.app','Nadia','female','male',33, 2.3300,48.8650, array['Sahara','Arabe','Famille'],                'Famille avant tout, originaire du grand Sud.'),
  ('a0000000-0000-4000-8000-000000000008','rayan.test@zewjouna.app','Rayan','male','everyone',25, 2.3550,48.8520, array['Algérois','Anglais','Gaming'],            'Dev le jour, gamer la nuit. Algérois 100%.'),
  ('a0000000-0000-4000-8000-000000000009','imene.test@zewjouna.app','Imène','female','male',29, -73.5673,45.5017, array['Kabylie','Français','Lecture'],          'Montréalaise, kabyle, lectrice insatiable.'),
  ('a0000000-0000-4000-8000-000000000010','walid.test@zewjouna.app','Walid','male','female',34, 3.0588,36.7538, array['Oranais','Arabe','Entrepreneuriat'],       'Entrepreneur basé à Alger, en quête de sérieux.'),
  ('a0000000-0000-4000-8000-000000000011','sara.test@zewjouna.app','Sara','female','male',24, 2.3480,48.8580, array['Kabylie','Kabyle','Danse','Café'],           'Danse, cafés et longues discussions. Kabyle et fière.'),
  ('a0000000-0000-4000-8000-000000000012','yanis.test@zewjouna.app','Yanis','male','female',32, 4.8500,45.7700, array['Aurès','Chaoui','Nature'],                 'Chaoui des Aurès, amoureux de randonnée et de nature.');

-- 1) Utilisateurs auth (loginables : email + mot de passe « zewjouna123 »).
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data
)
select
  '00000000-0000-0000-0000-000000000000', p.id, 'authenticated', 'authenticated',
  p.email, crypt('zewjouna123', gen_salt('bf')),
  now(), now(), now(),
  '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
from public._zew_seed p
on conflict (id) do nothing;

-- Identités e-mail (nécessaires pour la connexion par e-mail).
insert into auth.identities (
  provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at
)
select
  p.id::text, p.id,
  jsonb_build_object('sub', p.id::text, 'email', p.email, 'email_verified', true),
  'email', now(), now(), now()
from public._zew_seed p
on conflict (provider, provider_id) do nothing;

-- 2) Profils publics géolocalisés.
insert into public.profiles (
  user_id, display_name, bio, gender, looking_for, birthdate,
  community_tags, location, last_active_at, verified
)
select
  p.id, p.display_name, p.bio, p.gender, p.looking_for,
  make_date(extract(year from current_date)::int - p.age, 1, 15),
  p.tags,
  st_setsrid(st_makepoint(p.lng, p.lat), 4326)::geography,
  now() - (random() * interval '5 days'),
  (random() < 0.4)
from public._zew_seed p
on conflict (user_id) do update set
  display_name   = excluded.display_name,
  bio            = excluded.bio,
  gender         = excluded.gender,
  looking_for    = excluded.looking_for,
  birthdate      = excluded.birthdate,
  community_tags = excluded.community_tags,
  location       = excluded.location;

drop table public._zew_seed;
