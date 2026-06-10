# Plugin `notom-dev` — Bonnes pratiques de dev propagées à toutes les sessions Claude

**Date :** 2026-06-04
**Statut :** Design validé (brainstorming)
**Portée :** nouveau repo `notom-dev` (plugin Claude Code) + `.pre-commit-config.yaml` dans les 4 repos
**Dépend de :** [Workflow de dev et de release](./2026-06-04-dev-release-workflow-design.md) (projet #1)

---

## 1. Objectif

Faire en sorte que **chaque session Claude** — sur le laptop **et** en SSH sur les VM —
applique automatiquement les bonnes pratiques de dev/release de la plateforme :

- le **workflow** du projet #1 (`feat → dev → PR → release → prod`),
- des **commits structurés** et un **nommage de branches** cohérents,
- des **checks automatiques avant commit** (terrain vierge aujourd'hui),
- une **commande de release** vers la prod.

Le tout **distribué par un plugin Claude Code** (comme superpowers) et **composant avec**
superpowers plutôt que de le réécrire.

---

## 2. État actuel

- **Aucun test/lint/CI de qualité** : seules des workflows de déploiement existent ; pas de
  pytest, pas de `.pre-commit-config.yaml`, pas de lint.
- dbt (`notom-data-platform`) a des modèles + fichiers `*_models.yml`/`sources.yml` : socle
  présent pour des tests dbt et pour `dbt parse`.
- **Conventions déjà suivies (à entériner, pas à imposer)** :
  - Conventional Commits : `fix(oidc): …`, `feat(traefik): …`, `ci(prod): …`.
  - Nommage de branches : `feat/…`, `fix/…`.
- **Fait clé (lien projet #1)** : les dossiers app sur les VM sont des **clones git** des repos.
  Donc tout fichier committé dans un repo (ex. `.pre-commit-config.yaml`, `CLAUDE.md`) est
  **automatiquement présent en local ET en SSH sur la VM**, sans synchronisation.

---

## 3. Décisions

| Sujet | Décision |
|---|---|
| Primitif de propagation | **Plugin Claude Code** distribué par git, installé sur laptop + chaque VM (mise à jour `git pull`) |
| Relation à superpowers | **Composition** : réutilise TDD / requesting-code-review / verification-before-completion / finishing-a-development-branch ; ajoute le spécifique notom |
| Niveau d'enforcement | **Niveau 2 — garde-fous locaux** (hooks qui bloquent sur la machine) |
| Checks pre-commit (rapides) | **Anti-fuite de secrets**, **validation des configs**, **`dbt parse`** |
| Écartés du pre-commit | tests dbt réels + parsing DAG (trop lents → CI ultérieure), CI bloquante (Niveau 3, plus tard) |

---

## 4. Architecture du plugin

Trois composants packagés dans le repo `notom-dev` :

### 4.1 Skill `/release` (la procédure)

Encode le workflow du projet #1 :

```
feat/* → PR → dev (staging) → /release → PR dev→main → tag CalVer → CD prod
```

`/release` guide l'utilisateur : vérifie que `dev` est vert, liste les PR embarquées dans
`dev..main`, ouvre la PR `dev → main` ; après merge, la CD prod (projet #1) pose le tag CalVer
et met à jour le manifeste global. Le skill **délègue** aux skills superpowers pour les phases
génériques (revue de code, vérification avant complétion, clôture de branche).

### 4.2 Fragment de bonnes pratiques (contexte chargé)

Chargé dans chaque session pour que Claude *connaisse* les règles, sans les imposer durement :

- On travaille sur `dev`, **jamais directement sur `main`**.
- Commits **Conventional Commits**.
- Branches `feat/`, `fix/`, `chore/`, …
- On **lance les checks avant de commit**.
- Staging = clone git : on **commit/push depuis la VM** (pas de drift).
- Pour livrer : `/release`.

### 4.3 Hooks — garde-fous Niveau 2

Hooks qui **bloquent** (avec message d'explication) :

| Hook | Bloque | Mécanisme |
|---|---|---|
| Protection branche | `commit`/`push` direct sur `main` ; force-push sur branche protégée | Claude Code `PreToolUse` (inspection de la commande git) |
| Format commit | message hors Conventional Commits | hook commit-msg (pre-commit) + garde Claude |
| Anti-fuite secrets | commit contenant `.env`, clé privée, token | pre-commit (gitleaks/detect-secrets) |
| Validation configs | `docker compose config` / yamllint / Traefik / Authentik en échec | pre-commit |
| dbt parse | modèles dbt qui ne compilent pas | pre-commit (repo data-platform) |

**Échappatoire explicite** : variable d'env / flag documenté (ex. `NOTOM_SKIP_HOOKS=1` ou
`git commit --no-verify` encadré) pour les cas légitimes, afin que le filet ne devienne pas une
camisole. L'usage de l'échappatoire est journalisé/visible.

### 4.4 Moteur des checks — `.pre-commit-config.yaml` par repo

Le moteur réel des checks est un `.pre-commit-config.yaml` **committé dans chaque repo** (donc
présent en local et sur la VM via le clone git). Les hooks du plugin s'assurent qu'il tourne.
Avantage : protège aussi les **commits manuels**, pas seulement ceux passant par Claude.

Contenu par stack :
- **Tous** : anti-secrets (gitleaks/detect-secrets), yamllint, format commit-msg.
- **gateway** : `docker compose config`, validation Traefik (dynamic/static), lint blueprint Authentik.
- **analytics** : `docker compose config`, vérif syntaxe `superset_config.py`.
- **data-platform** : `docker compose config`, `dbt parse` (compile les modèles, sans DB).

---

## 5. Distribution & installation

- **Repo dédié** `notomio/notom-dev` (séparation claire, versionnable indépendamment).
- Installation Claude Code (marketplace git / plugin install) **une fois** sur le laptop et sur
  chaque VM. Mise à jour par `git pull` / réinstall.
- Le `.pre-commit-config.yaml` est, lui, committé **dans chaque repo applicatif** (pas dans le
  plugin) ; le plugin documente/installe le hook `pre-commit` au besoin.

---

## 6. Comportement attendu (exemple)

*« Je corrige un bug OIDC »* avec le plugin installé :

```
Claude travaille sur dev (jamais main).
Avant un commit "fix(oidc): …" :
   secrets ✓   docker compose config ✓   dbt parse ✓
Si tentative de push sur main :
   BLOQUÉ → "passe par une PR dev→main"
Pour livrer :
   /release → procédure guidée jusqu'à la prod (tag CalVer + manifeste)
```

---

## 7. Hors-scope (YAGNI)

- **CI bloquante** sur les PR (Niveau 3) — pourra venir plus tard, réutilisera le même
  `.pre-commit-config.yaml` + tests dbt.
- **Tests dbt réels + parsing DAG** en pre-commit (trop lents) — destinés à la CI.
- **Environnement de dev local** reproductible (la boucle sur VM convient — projet #1).
- Réécriture des skills superpowers (on les réutilise).

---

## 8. Travaux à réaliser (vue d'ensemble)

**Repo `notom-dev` (nouveau) :**
- [ ] Squelette de plugin Claude Code (manifeste, structure).
- [ ] Skill `/release` (procédure, délégation aux skills superpowers).
- [ ] Fragment de bonnes pratiques (contexte chargé).
- [ ] Hooks : protection branche (`PreToolUse`), garde format commit, intégration pre-commit.
- [ ] Échappatoire documentée + journalisation.
- [ ] Doc d'installation (laptop + VM).

**Chaque repo applicatif (`gateway`, `analytics`, `data-platform`) :**
- [ ] `.pre-commit-config.yaml` adapté au stack (cf. §4.4).
- [ ] (data-platform) brancher `dbt parse`.

**Note enforcement :** les hooks ciblent les sessions Claude ; le `.pre-commit-config.yaml`
couvre en plus les commits manuels.

---

## 9. Critères de succès

1. Le plugin installé, **toute** session Claude (laptop + VM) connaît et applique le workflow.
2. Un `commit`/`push` direct sur `main` est **bloqué** avec un message clair.
3. Un commit contenant un secret, une config invalide ou un modèle dbt cassé est **bloqué**
   avant d'entrer dans l'historique.
4. `/release` mène une release de bout en bout en s'appuyant sur le projet #1.
5. Le plugin **réutilise** superpowers (pas de duplication) et reste cohérent avec les
   conventions déjà en place (Conventional Commits, `feat/`/`fix/`).
6. Une échappatoire existe et est documentée pour les cas légitimes.
