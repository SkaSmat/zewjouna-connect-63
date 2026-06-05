# CLAUDE.md — ZEWJOUNA

Application de rencontre style **Bumble** dédiée à la **diaspora algérienne**.
Le différenciateur produit : le **matching communautaire** (régions, langues,
centres d'intérêt) en plus de la géolocalisation.

## Stack

- **Frontend** : TanStack Start + React 19 + TypeScript + Tailwind v4 +
  shadcn/ui. Généré/édité via Lovable. UI dans `src/routes` et `src/components`.
- **Backend** : Supabase — Postgres + **PostGIS** (géoloc), Auth, Storage
  (bucket privé), Realtime (chat), **RLS stricte**. Tout le SQL vit dans
  `supabase/` (voir `supabase/README.md`).
- Projet Supabase : ref `rpolxheihjmhrpqbmpsq`.

## Répartition du travail

- **Lovable** : scaffolding UI, écrans, CRUD simple.
- **Claude Code** (ici) : tout ce qui touche au **matching**, aux **policies
  RLS**, à la **modération** et aux **Edge Functions** — là où une erreur =
  fuite de données personnelles = critique sur une app de dating.

## Modèle de données (`public`)

| Table | Clés |
|---|---|
| `profiles` | `user_id` (PK = `auth.users`), `display_name`, `bio`, `photos[]`, `birthdate`, `gender`, `looking_for`, `location` (geography Point 4326), `community_tags[]`, `verified`, `last_active_at` |
| `swipes` | `swiper_id`, `swiped_id`, `action` (like/pass) — unique `(swiper_id, swiped_id)` |
| `matches` | paire ordonnée `user_a < user_b`, `expires_at`, `conversation_started` |
| `messages` | `match_id`, `sender_id`, `content`, `read_at` |
| `blocks` | `blocker_id`, `blocked_id` |
| `reports` | `reporter_id`, `reported_id`, `reason`, `status` |

Enums : `gender`, `looking_for`, `swipe_action`, `report_status`.

## API consommée par le frontend (contrat à ne pas casser)

- `supabase.rpc("get_candidates_adaptive", { p_target, p_min_age, p_max_age, p_limit })`
  → feed de découverte (`CandidateRow[]`).
- `supabase.rpc("get_match_profile", { p_target })`
  → profil public-safe d'un match (`MatchProfileRow`).
- Edge Function `signed-photo-urls` (body `{ target_id }` → `{ urls }`)
  → URLs signées des photos d'autrui (bucket privé).
- Storage bucket `profile-photos`, chemins `"<uid>/<fichier>"`.
- Realtime : channel sur `messages` filtré par `match_id`.

Le contrat TypeScript correspondant est dans `src/lib/database.types.ts`.

## Règles métier

1. **Match** : un like réciproque déclenche le trigger `handle_swipe` qui crée
   le `match` avec une fenêtre de 24 h (`expires_at`).
2. **Bumble** : dans un couple hétéro, seule la femme peut envoyer le premier
   message (`can_send_message`). Le premier message lève l'expiration.
3. **Découverte** : filtres durs (genre réciproque, âge, distance PostGIS,
   exclusion des déjà-swipés et des bloqués) ; rayon élargi adaptativement pour
   le cold-start ; classement par tags communs → proximité → activité récente.

## Sécurité — non négociable

- RLS active sur **toutes** les tables. Un utilisateur ne lit que sa propre
  ligne `profiles` ; les autres profils passent par les RPC `security definer`.
- Messages réservés aux deux membres du match.
- Photos en **bucket privé**, URLs signées éphémères uniquement.
- `report`/`block` disponibles dès le MVP.
- **Auditer toute modification des policies RLS** avant de la pousser
  (`/security-review`).

## Hors périmètre MVP

Vérification photo IA, super-likes/boosts payants, appels vidéo, reco ML,
stories. À ajouter seulement après validation du MVP.

## Commandes

```bash
bun install            # dépendances (registre npm public)
bun run dev            # frontend en local
bun run lint           # eslint
# backend : voir supabase/README.md (supabase db push / functions deploy)
```
