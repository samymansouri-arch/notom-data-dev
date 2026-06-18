# Release « tout » + note Slack consolidée

**Date :** 2026-06-18
**Statut :** Design validé (brainstorming)
**Portée :** plugin `notom-data-dev` (skill `release`) + `notom-data-infra` (secret webhook)

---

## 1. Objectif

Faire évoluer le skill `notom-data-dev:release` pour qu'une seule invocation puisse :

1. **livrer en prod `main` des 3 apps** (`notom-connect-analytics`, `notom-data-platform`,
   `notom-cloud-gateway`) en un seul geste,
2. **poster une note de release consolidée** sur un **canal Slack dédié**.

Le mode actuel « une app à la fois » est **conservé**.

## 2. Contexte / existant

- Chaque app a son `deploy-prod.yml` (`workflow_dispatch`, sans `ref` = déploie `main`) qui :
  déploie sur sa VM → pose un **tag CalVer** (`analytics-…`, `data-platform-…`, `gateway-…`) →
  met à jour le **manifeste global** `notom-data-infra@main:prod-versions.yaml`
  (version de l'app + `platform_version`) → crée la **GitHub Release**.
- Le skill `release` (skills/release/SKILL.md) orchestre **une** app : propose le périmètre
  (commits `LAST..origin/main`), confirme, `gh workflow run deploy-prod.yml`, surveille, vérifie.
- Aucune notification Slack n'existe dans le flux de release. Le `slack_webhook_url` ajouté côté
  data-platform sert aux **alertes Airflow** (canal différent) — **à ne pas réutiliser ici**.

## 3. Décisions actées (brainstorming)

| Sujet | Décision |
|---|---|
| Périmètre du mode « tout » | **Seulement les apps avec du nouveau** (commits non releasés). Les apps à jour sont sautées. |
| Forme de la note Slack | **Une seule note consolidée** (toutes les apps livrées dans un message). |
| Garde-fou | **Une confirmation unique** (récap global), puis exécution sans re-demander. |
| Où vit l'orchestration | **Dans le skill** (approche A), pas de workflow CI parapluie. |
| Note postée par | **Le skill** (curl du webhook), après succès de toutes les releases. |
| Stockage du webhook | **Secret Scaleway dédié, codifié en Terraform.** |

## 4. Architecture (approche A — orchestré par le skill)

```
Utilisateur ──"release tout"──▶ skill release (mode tout)
   │ 1. calcule périmètre (3 repos : LAST..origin/main)
   │ 2. récap unique + 1 confirmation
   │ 3. pour chaque app concernée (séquentiel) :
   │        gh workflow run deploy-prod.yml --repo notomio/<repo>
   │        gh run watch … --exit-status   → récupère le nouveau tag
   │        (le CI fait : déploy + tag + manifest + GitHub Release)
   │ 4. fetch webhook dédié (scw secret version access) → curl note consolidée
   └ 5. vérif (tags, Releases, prod-versions.yaml, apps répondent)
```

## 5. Composants

### 5.1 Skill `release` — nouveau mode « tout »
- **Détection du mode** depuis la phrase : « release tout / livrer tout / release all / tout mettre
  en prod » → mode **tout** ; « release <app> » → mode **une app** (inchangé).
- **Périmètre** : pour chacun des 3 repos :
  ```bash
  git -C <repo> fetch origin --tags --quiet
  LAST=$(git -C <repo> tag --list "<prefix>-*" --sort=-creatordate | head -1)
  git -C <repo> log --oneline ${LAST:+$LAST..}origin/main
  ```
  Apps sans commit nouveau → **sautées** (listées comme « à jour »).
- **Récap unique** : tableau apps-à-livrer (+ leurs commits/PR) et apps sautées ; avertissements
  (gateway = blip routage pour tous les services ; analytics/data-platform = restart ~30-60 s).
  **Une** confirmation.
- **Exécution séquentielle** : pour chaque app concernée → `gh workflow run deploy-prod.yml
  --repo notomio/<repo>` puis `gh run watch <id> --repo notomio/<repo> --exit-status` ; récupère le
  nouveau tag (`git ls-remote --tags` / `gh release list`).
- **Note Slack** : après succès de **toutes** les releases (cf. 5.3).
- **Vérif finale** : tags posés, GitHub Releases créées, `prod-versions.yaml` à jour, apps prod
  répondent.

### 5.2 Webhook Slack dédié (Terraform, `notom-data-infra`)
- Nouvelle variable sensible `slack_release_webhook_url` (module + env prod ; `default = ""`).
- Nouvelle ressource **`scaleway_secret` `slack-release-webhook`** (+ `scaleway_secret_version`)
  dans le projet prod, valeur depuis `envs/prod/terraform.tfvars` (gitignored) ;
  `terraform.tfvars.example` documenté.
- Le skill lit la valeur via `scw secret version access` au moment de poster.
- ≠ `slack_webhook_url` (alertes Airflow) : canal et usage distincts.

### 5.3 Format de la note (Slack mrkdwn)
La note **ne liste que les apps réellement livrées** (bullets). Les apps sautées (déjà à jour)
apparaissent au plus dans un **petit pied de note** informatif, jamais comme une livraison.
```
🚀 Release prod notom-data — platform <platform_version> — <YYYY-MM-DD>
• connect-analytics → analytics-2026.06.18  (2 PR)
    – NUMI — Exploration Télémétrie (#15)
    – dev-init staging (#14)
• data-platform → data-platform-2026.06.18  (6 PR)
    – alertes Slack échec asset-triggered (#36) …
manifest: prod-versions.yaml
_(non releasées car déjà à jour : cloud-gateway)_
```
Sources : `platform_version` et versions depuis `prod-versions.yaml` après releases ; changelog =
les commits/PR déjà calculés au périmètre (5.1).

## 6. Gestion d'erreur

- Releases **séquentielles**. Si une app **échoue** (workflow en erreur) : **arrêt** des suivantes.
- **Pas de note Slack automatique** dans ce cas : on rapporte à l'utilisateur ce qui est passé /
  pas passé et on lui demande quoi faire (re-tenter, rollback, poster une note partielle).
- Pas de release « à moitié » silencieuse.

## 7. Tests

- **Calcul de périmètre à blanc** (aucun déploiement) : la liste apps/commits est correcte.
- **Cas « rien à livrer »** (toutes à jour) : message clair, **aucun** post Slack.
- **Format de la note** : valider le rendu en postant une note de **test** sur le canal dédié (ou
  un canal de test) avant câblage du flux réel.

## 8. Hors-scope (volontaire)

- Pas de bouton CI / workflow parapluie (= approche B écartée).
- Pas de release multi-repo **atomique** : reste séquentielle, app par app.
- Pas de changement du flux `dev → main` (toujours par PR, intégration sans déploiement).
- Pas de réutilisation du webhook d'alertes data-platform.
