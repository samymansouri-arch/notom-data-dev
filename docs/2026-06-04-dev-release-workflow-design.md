# Workflow de dev et de release — Cloud Data Platform

**Date :** 2026-06-04
**Statut :** Design validé (brainstorming)
**Portée :** 4 repos — `notom-cloud-gateway`, `notom-connect-analytics`, `notom-data-platform`, `notom-data-infra`

---

## 1. Objectif

Définir un workflow de développement et de mise en production *state of the art* pour la
plateforme, avec :

- un chemin **staging → prod** propre et contrôlé,
- des **releases groupant plusieurs PR**,
- un **numéro de version** par application **et** un **numéro de version prod global**,
- un **rollback** simple.

Ce design **ne change pas** la boucle de développement quotidienne, qui fonctionne déjà
bien (voir §3). Il se concentre sur la partie release/déploiement, qui est le vrai manque.

---

## 2. État actuel (ce qui existe déjà)

- **Dev sur les VM staging** : le dossier applicatif sur chaque VM staging est un dépôt git ;
  le développeur édite directement sur la VM (Airflow, Superset) et **commit/push depuis la
  VM**. Rapide, sur infra réelle, sans drift. → **À conserver tel quel.**
- **VM staging fonctionnelles** pour `data-platform` et `analytics` (avec secrets et
  sous-domaines staging).
- **CD prod par repo** (`deploy-prod.yml`) : `push sur main` → fetch `.env` depuis Scaleway
  Secret Manager → (gateway : rendu du template Traefik) → `rsync -avz --delete` du repo vers
  `/opt/...` sur la VM → `docker compose pull && up -d`. `data-platform` et `analytics`
  passent par un **bastion (ProxyJump)** ; la gateway en IP publique directe.
- **`environment: production`** déjà déclaré dans les workflows (support de l'approbation
  manuelle disponible mais non activé).
- Branche **`dev`** déjà présente sur `data-platform` (pas encore sur les autres apps).
- Gateway multi-env **en cours** (`feat/multi-env-traefik`, `feat/fetch-env-from-secret-manager`,
  `deploy-dev.yml` + `environment: staging`).

### Ce qui manque (objet de ce design)

1. Une branche d'intégration **`dev`** standardisée sur les **3 repos apps**.
2. Un **mécanisme de release** : regrouper plusieurs PR, poser un **tag de version**.
3. Un **rollback** : redéployer une version antérieure sans stress.
4. Un **numéro de version prod global**.
5. La **mise à niveau de la CD prod** pour déployer un *tag* (immuable) plutôt que l'état
   courant de `main`.

---

## 3. Boucle de développement quotidienne (inchangée)

Conservée à l'identique. Rappel du cycle, pour mémoire :

1. Sur la VM staging : `git checkout -b feat/xxx`.
2. Édition directe sur la VM (VS Code Remote-SSH ou éditeur au choix) ; Airflow/Superset
   rechargent à chaud.
3. Validation en conditions réelles sur l'infra staging.
4. `git commit && git push` **depuis la VM**.
5. Ouverture de la PR `feat/xxx → dev` sur GitHub.

**Aucune action requise** pour cette partie ; elle est déjà en place.

---

## 4. Modèle de branches et environnements

### 4.1 Branches (identique sur les 3 repos applicatifs)

| Branche      | Rôle                                   | Déploie vers                          |
|--------------|----------------------------------------|---------------------------------------|
| `feat/*`     | dev d'une fonctionnalité               | VM staging (branche checkout sur la VM) |
| `dev`        | état intégré (plusieurs PR fusionnées) | staging (validation d'ensemble)       |
| `main`       | état releasé                           | **prod** (CD)                         |
| tag `app-YYYY.MM.DD[.N]` | snapshot immuable de release | sert au rollback                    |

```
  feat/x ┐
  feat/y ├── PR ──▶ dev ───────────────▶  STAGING
  feat/z ┘                │
                          └── PR "release" ──▶ main ──▶ PROD (CD)
                                                 │
                                          tag app-2026.06.04
                                                 │
                                          maj prod-versions.yaml (version globale)
```

### 4.2 Principe-clé — asymétrie staging / prod (volontaire)

- **Staging = poste de dev sur infra réelle.** Dossier app = clone git *mutable* piloté par le
  développeur (choix de la branche, édition, commit/push). « Déployer dev sur staging » =
  `git pull` sur la VM. **Aucun `rsync --delete` externe** ne vient écraser le travail en cours.
- **Prod = déploiement immuable.** La CD checkout un **tag** précis et le déploie. Pas de dev
  sur la prod → pas de drift. Le rollback = relancer la CD sur un tag antérieur.

### 4.3 Trois environnements isolés (staging = miroir complet)

```
            STAGING (miroir)                         PROD (existant)
  ┌─────────────────────────────┐        ┌─────────────────────────────┐
  │ gateway + Authentik staging  │        │ gateway + Authentik prod     │
  │ VM data-platform staging     │        │ VM data-platform prod        │
  │ VM analytics (Superset) stg  │        │ VM analytics (Superset) prod │
  │ secrets *-env-staging        │        │ secrets *-env-prod           │
  │ staging.*.notom.io           │        │ *.notom.io                   │
  └─────────────────────────────┘        └─────────────────────────────┘
```

Choix assumé : isolation totale, y compris une gateway/Authentik staging dédiée (coût : un 2ᵉ
Authentik à maintenir ; gain : pouvoir tester aussi les changements gateway sans risque prod).

---

## 5. Mécanisme de release

### 5.1 Déclenchement

Une release = **une PR `dev → main`** par repo. GitHub liste automatiquement l'ensemble des PR
embarquées dans le diff `dev..main`. La fusion de cette PR déclenche la CD prod (§6).

### 5.2 Versioning — CalVer

- **Par application** : tag = `<prefixe>-YYYY.MM.DD`, avec suffixe `.N` si plusieurs releases le
  même jour. Préfixes figés (un par repo) :
  - `notom-cloud-gateway` → `gateway-2026.06.04`
  - `notom-connect-analytics` → `analytics-2026.06.04`
  - `notom-data-platform` → `data-platform-2026.06.04.2` (`.2` = 2ᵉ release du jour)
- **Global prod** : `platform_version = YYYY.MM.N` (N = compteur de releases plateforme du mois).

Aucune décision humaine de numéro de version (pas de débat majeur/mineur). Le tag est posé
**automatiquement** par la CD au moment du déploiement.

### 5.3 Cadence

**Indépendante par repo** : chaque app release à son rythme. Pour un rare changement croisé
(ex. nouveau client OIDC côté gateway + consommation côté app), on release la gateway d'abord,
puis l'app. La cohérence d'ensemble est **observable** via le manifeste global (§7), sans être
imposée.

---

## 6. CD prod (mise à niveau)

Évolution de la `deploy-prod.yml` existante. Étapes, dans l'ordre, au merge de `dev → main` :

1. **Calcul + pose du tag CalVer** `app-YYYY.MM.DD[.N]` sur le commit de `main`.
2. **Fetch `.env`** depuis Scaleway Secret Manager prod *(inchangé)*.
3. **Déploiement du tag** sur la VM prod : checkout du tag → `rsync -avz --delete` →
   `docker compose pull && up -d` *(mécanisme inchangé, mais sur un ref figé)*.
4. **Mise à jour du manifeste global** `prod-versions.yaml` dans `notom-data-infra` (commit
   automatique + bump de `platform_version`).

### 6.1 Déploiement par tag (immuable) + rollback

- La CD déploie un **ref figé** (le tag), pas « le dernier état de `main` ».
- **Rollback** : `workflow_dispatch` avec une entrée `ref` (menu déroulant des tags). Relancer
  la CD sur un tag antérieur (ex. `connect-analytics-2026.06.01`) redéploie exactement ce code.
- ⚠️ **Limite explicite** : le rollback porte sur le **code/config versionné en git**, **pas**
  sur les secrets (toujours la version courante du Secret Manager). Un changement de secret
  incompatible n'est pas annulé par un rollback de code.

### 6.2 Garde-fou « approbation prod » (recommandé)

Activer une **protection rule** sur l'`environment: production` (déjà déclaré) : la CD se met en
pause et exige **un clic d'approbation** avant de toucher la prod. La fusion `dev → main`
prépare la release ; l'approbation déclenche réellement le déploiement.

### 6.3 Concurrence

Conserver `concurrency: group: deploy-prod, cancel-in-progress: false` (déjà en place) pour
éviter deux déploiements prod simultanés.

---

## 7. Numéro de version prod global (manifeste)

Fichier unique versionné dans `notom-data-infra`, source de vérité de « ce qui tourne en prod » :

```yaml
# notom-data-infra/prod-versions.yaml  (mis à jour automatiquement par chaque CD prod)
platform_version: 2026.06.2
updated_at: 2026-06-04T17:30:00Z
apps:
  notom-cloud-gateway:     2026.05.20
  notom-connect-analytics: 2026.06.04
  notom-data-platform:     2026.06.04.2
```

- Chaque app avance indépendamment ; le fichier donne **un seul numéro** pour décrire l'état
  prod global.
- L'**historique git** de ce fichier répond à « quelle était la prod il y a 2 semaines ? ».
- Mise à jour : la CD prod de chaque app, après déploiement réussi, édite sa propre entrée,
  incrémente `platform_version` et `updated_at`, puis commit/push (token avec write sur
  `notom-data-infra`).

---

## 8. Repo infra (`notom-data-infra`, Terraform)

Flux distinct des apps (pas de docker compose, pas de tag CalVer applicatif) :

- Changements via PR ; **`terraform plan`** en CI sur la PR (revue du plan).
- **`terraform apply`** au merge sur `main` (avec, si souhaité, la même protection rule
  d'approbation que la prod applicative).
- Séparation des dossiers/états **`staging/`** et **`prod/`** (aujourd'hui seul `prod/` existe ;
  un dossier/état `staging/` reflétant les VM staging actuelles est à formaliser).
- Ce repo **héberge** `prod-versions.yaml` (§7) et, idéalement, les **templates de workflows**
  partagés entre repos pour éviter la divergence.

> Note : le détail du flux Terraform staging n'a pas été approfondi en brainstorming ; il est
> volontairement laissé léger ici et sera précisé au moment du plan d'implémentation.

---

## 9. Sécurité, secrets, points d'attention

- **Secrets non versionnés** : `.env` vient toujours du Secret Manager (staging ou prod) au
  runtime — jamais committé. Conséquence assumée sur le rollback (§6.1).
- **Token d'écriture inter-repo** : la mise à jour du manifeste nécessite un token GitHub avec
  write sur `notom-data-infra` (PAT fine-grained ou GitHub App), stocké en secret.
- **Garde-fou anti-drift staging (optionnel)** : un check périodique `git status --porcelain`
  sur les VM staging signale des modifs non committées qui traînent.
- **Cohérence des workflows** : factoriser les 3 `deploy-prod.yml` (très similaires) via des
  templates/reusable workflows pour éviter la divergence constatée aujourd'hui.

---

## 10. Travaux à réaliser (vue d'ensemble, par repo)

**Tous les repos apps (`gateway`, `analytics`, `data-platform`) :**
- [ ] Créer/standardiser la branche `dev` + protection de branche (`main` et `dev`).
- [ ] Convention de PR `dev → main` pour les releases.
- [ ] Mettre à niveau `deploy-prod.yml` : tag CalVer auto + déploiement par tag + entrée
      `workflow_dispatch ref` pour rollback.
- [ ] Étape de mise à jour de `prod-versions.yaml` dans `notom-data-infra`.
- [ ] Activer la protection rule d'approbation sur `environment: production`.

**`notom-data-infra` :**
- [ ] Créer `prod-versions.yaml` (état initial des versions prod actuelles).
- [ ] Provisionner le token d'écriture inter-repo + secret associé.
- [ ] Formaliser le flux Terraform `staging/` (à détailler au plan).
- [ ] (Optionnel) Centraliser les reusable workflows.

**Gateway :** finaliser le multi-env en cours (cohérent avec ce design).

---

## 11. Hors-scope (YAGNI)

- Mise en place d'un **environnement de dev local** reproductible (la boucle sur VM convient).
- **Release plateforme synchronisée** forçant des versions communes (on garde l'indépendance
  + manifeste d'observation).
- **Semver / conventional commits / release-please** (CalVer retenu).
- Rollback **des secrets/données** (hors périmètre du versioning de code).

---

## 12. Critères de succès

1. Une release prod = une PR `dev → main` fusionnée → tag CalVer posé automatiquement.
2. La prod déploie un **tag immuable** ; un rollback se fait en relançant la CD sur un tag
   antérieur (≤ 1 action).
3. `prod-versions.yaml` reflète en permanence l'état prod, avec un **numéro global** et un
   historique exploitable.
4. Les 3 repos apps suivent le **même** modèle de branches et la **même** CD (factorisée).
5. La boucle de dev quotidienne sur staging reste inchangée.
