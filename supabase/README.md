# Backend Supabase — ZEWJOUNA

Backend de l'app de rencontre (diaspora algérienne, style Bumble) : schéma
Postgres + PostGIS, RLS stricte, triggers de matching, RPC de découverte et une
Edge Function pour les photos privées. Tout est aligné sur le contrat attendu
par le frontend (`src/lib/database.types.ts`).

## Contenu

| Fichier | Rôle |
|---|---|
| `migrations/20260605000000_init.sql` | Schéma complet : tables, enums, index, RLS, triggers, RPC, bucket Storage, Realtime |
| `functions/signed-photo-urls/` | Edge Function : URLs signées des photos d'autrui (bucket privé) |
| `config.toml` | Config projet (ref `rpolxheihjmhrpqbmpsq`) |

## Déploiement

Prérequis : [Supabase CLI](https://supabase.com/docs/guides/cli) installé et un
accès au projet `rpolxheihjmhrpqbmpsq`.

```bash
# 1. Se connecter et lier le projet distant
supabase login
supabase link --project-ref rpolxheihjmhrpqbmpsq

# 2. Appliquer la migration (crée tables, RLS, RPC, bucket, etc.)
supabase db push

# 3. Déployer l'Edge Function
supabase functions deploy signed-photo-urls
```

`SUPABASE_URL`, `SUPABASE_ANON_KEY` et `SUPABASE_SERVICE_ROLE_KEY` sont injectés
automatiquement dans les Edge Functions par la plateforme — rien à configurer.

> Alternative sans CLI : ouvrir le SQL Editor du dashboard Supabase et coller le
> contenu de la migration, puis créer l'Edge Function via le dashboard.

## Garanties de sécurité (dating = données sensibles)

- **RLS dès le jour 1.** Un profil ne lit que **sa propre** ligne `profiles`.
  Les données des autres ne transitent que par les RPC `security definer`
  (`get_candidates_adaptive`, `get_match_profile`) qui ne renvoient que des
  colonnes publiques (jamais l'email, la `location` brute, etc.).
- **Messages** lisibles uniquement par les deux membres du match ; l'envoi est
  filtré par `can_send_message` (blocage, expiration 24h, règle Bumble).
- **Photos** dans un bucket **privé** ; aucune URL publique permanente. Les
  photos d'autrui passent par des URLs signées (10 min) générées côté serveur.
- **Matchs** créés uniquement par trigger serveur sur like réciproque — aucun
  client ne peut en insérer.

## Règles métier implémentées

- Like réciproque → trigger `handle_swipe` crée un `match` (paire ordonnée
  `user_a < user_b`) avec `expires_at = now() + 24h`.
- Premier message → trigger `handle_message` lève l'expiration
  (`conversation_started = true`).
- Règle Bumble : dans un couple hétéro, seule la femme peut initier la
  conversation (vérifié dans `can_send_message`).
- Découverte adaptative : rayon de recherche élargi (50 km → 2000 km) jusqu'à
  atteindre `p_target` profils, puis classement par tags communautaires
  communs, proximité, puis activité récente.

## Étapes manuelles restantes

- Vérifier dans **Auth → Providers** que l'email (et éventuellement des OAuth)
  est activé.
- Configurer l'URL de redirection / Site URL dans **Auth → URL Configuration**.
