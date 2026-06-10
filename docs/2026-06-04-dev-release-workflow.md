# Workflow dev/release — Plan d'implémentation (Projet #1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Doter les 3 repos applicatifs (gateway, analytics, data-platform) d'un workflow `feat → dev → release PR → main → CD prod` avec tags CalVer immuables, rollback, garde-fou d'approbation, et un manifeste de version prod global dans `notom-data-infra`.

**Architecture :** La logique partagée (calcul du tag CalVer, mise à jour du manifeste) vit dans `notom-data-infra/scripts/release/` (Python testé). Chaque CD prod d'app garde ses étapes de déploiement existantes (rsync + docker compose) et ajoute : (1) un input `ref` pour redéployer un tag (rollback), (2) après déploiement, la création du tag CalVer sur le repo app, (3) la mise à jour du manifeste global dans infra via un PAT. La protection de branche force le passage par PR ; l'environnement `production` exige une approbation.

**Tech Stack :** GitHub Actions, `gh` CLI, Python 3 + PyYAML, bash/jq, Scaleway CLI (existant), SSH/rsync (existant).

**Référence spec :** `docs/specs/2026-06-04-dev-release-workflow-design.md`

**État de départ (constaté) :**
- 4 repos sous `notomio/`, branche par défaut `main`. Aucun tag nulle part.
- CD prod par repo (`.github/workflows/deploy-prod.yml`) : `on: push: [main]` + `workflow_dispatch` → fetch `.env` (Scaleway Secret Manager) → rsync `--delete` → `docker compose pull && up -d`. `environment: production` déjà déclaré. `concurrency: deploy-prod`.
- Spécificités : gateway = IP publique directe (`vars.SCW_VM_PUBLIC_IP`) + étape de rendu de template Traefik + `deploy-dev.yml` (staging). analytics & data-platform = via bastion (`vars.SCW_BASTION_IP/PORT`, `vars.SCW_VM_PRIVATE_IP`). data-platform = étape `chown 50000:0`. analytics = copie `.env` → `docker/.env`.
- Branche `dev` : présente sur data-platform uniquement.
- `gh` authentifié (`samymansouri-arch`). Python 3.9.

**Conventions du plan :**
- `<INFRA>` = clone local `notom-data-infra`. `<GW>`/`<ANALYTICS>`/`<DP>` = clones des repos apps.
- Tous les `gh api`/`gh` supposent les droits admin sur `notomio/*`.
- On ne touche JAMAIS `main` en direct : chaque changement passe par une branche `feat/*` + PR (on s'applique le workflow qu'on installe).

---

## Phase 0 — Prérequis (manuel, une fois)

### Task 0.1 : Créer le token d'écriture inter-repo pour le manifeste

Le manifeste vit dans `notom-data-infra` ; les workflows des 3 apps doivent y pousser un commit. Le `GITHUB_TOKEN` d'un workflow n'a pas accès aux autres repos → il faut un PAT fine-grained.

- [ ] **Step 1 : Créer le PAT fine-grained**

Sur GitHub → Settings → Developer settings → Fine-grained tokens → *Generate new token* :
- Resource owner : `notomio`
- Repository access : *Only select repositories* → `notom-data-infra`
- Permissions : *Repository permissions* → **Contents : Read and write**
- Expiration : 1 an (noter la date de renouvellement)
- Nommer : `notom-manifest-write`

Copier la valeur du token (commence par `github_pat_…`).

- [ ] **Step 2 : Ajouter le token comme secret dans les 3 repos apps**

```bash
for repo in notom-cloud-gateway notom-connect-analytics notom-data-platform; do
  gh secret set NOTOM_MANIFEST_WRITE_TOKEN \
    --repo notomio/$repo \
    --body "github_pat_COLLER_ICI"
done
```

- [ ] **Step 3 : Vérifier**

```bash
for repo in notom-cloud-gateway notom-connect-analytics notom-data-platform; do
  echo "== $repo =="; gh secret list --repo notomio/$repo | grep NOTOM_MANIFEST_WRITE_TOKEN
done
```
Attendu : la ligne `NOTOM_MANIFEST_WRITE_TOKEN` apparaît pour chaque repo.

---

## Phase 1 — Fondation versioning (`notom-data-infra`)

Toute la Phase 1 se fait sur une branche `feat/release-tooling` de `<INFRA>`.

### Task 1.1 : Créer la branche de travail dans infra

- [ ] **Step 1 : Brancher depuis main à jour**

```bash
cd <INFRA>
git checkout main && git pull
git checkout -b feat/release-tooling
```

### Task 1.2 : Le manifeste de version prod initial

**Files:**
- Create: `<INFRA>/prod-versions.yaml`

- [ ] **Step 1 : Créer le manifeste avec l'état initial**

```yaml
# prod-versions.yaml — source de vérité de ce qui tourne en prod.
# Mis à jour automatiquement par la CD prod de chaque app (scripts/release/manifest.py).
# NE PAS éditer à la main (sauf initialisation).
platform_version: "2026.06.0"
updated_at: "2026-06-04T00:00:00Z"
apps:
  notom-cloud-gateway: "pre-versioning"
  notom-connect-analytics: "pre-versioning"
  notom-data-platform: "pre-versioning"
```

- [ ] **Step 2 : Commit**

```bash
cd <INFRA>
git add prod-versions.yaml
git commit -m "feat(release): add initial prod-versions manifest"
```

### Task 1.3 : Script CalVer — calcul du prochain tag (TDD)

**Files:**
- Create: `<INFRA>/scripts/release/calver.py`
- Test: `<INFRA>/scripts/release/test_calver.py`

Règle : premier tag du jour = `<prefix>-YYYY.MM.DD` ; les suivants = `…DD.2`, `…DD.3`. Le tag sans suffixe compte comme l'occurrence n°1.

- [ ] **Step 1 : Écrire le test qui échoue**

```python
# <INFRA>/scripts/release/test_calver.py
import pytest
from calver import next_tag

PREFIX = "analytics"
DATE = "2026.06.04"

def test_first_tag_of_the_day_has_no_suffix():
    assert next_tag(PREFIX, DATE, existing=[]) == "analytics-2026.06.04"

def test_unrelated_tags_are_ignored():
    existing = ["gateway-2026.06.04", "analytics-2026.06.01"]
    assert next_tag(PREFIX, DATE, existing=existing) == "analytics-2026.06.04"

def test_second_tag_of_the_day_gets_suffix_2():
    existing = ["analytics-2026.06.04"]
    assert next_tag(PREFIX, DATE, existing=existing) == "analytics-2026.06.04.2"

def test_third_tag_of_the_day_gets_suffix_3():
    existing = ["analytics-2026.06.04", "analytics-2026.06.04.2"]
    assert next_tag(PREFIX, DATE, existing=existing) == "analytics-2026.06.04.3"

def test_gaps_in_suffixes_take_max_plus_one():
    existing = ["analytics-2026.06.04", "analytics-2026.06.04.5"]
    assert next_tag(PREFIX, DATE, existing=existing) == "analytics-2026.06.04.6"
```

- [ ] **Step 2 : Lancer le test pour le voir échouer**

```bash
cd <INFRA>/scripts/release && python3 -m pytest test_calver.py -v
```
Attendu : FAIL (`ModuleNotFoundError: No module named 'calver'`).

- [ ] **Step 3 : Implémenter `calver.py`**

```python
# <INFRA>/scripts/release/calver.py
"""Calcule le prochain tag CalVer pour une app donnée.

Format : <prefix>-YYYY.MM.DD pour le 1er du jour, puis .2, .3, ... ensuite.
"""
import argparse
import re
import subprocess
import sys


def next_tag(prefix, date, existing):
    """date au format 'YYYY.MM.DD'. existing : liste de tags déjà posés."""
    base = f"{prefix}-{date}"
    suffix_re = re.compile(rf"^{re.escape(base)}(?:\.(\d+))?$")
    occurrences = []
    for tag in existing:
        m = suffix_re.match(tag)
        if m:
            occurrences.append(int(m.group(1)) if m.group(1) else 1)
    if not occurrences:
        return base
    return f"{base}.{max(occurrences) + 1}"


def _git_tags():
    out = subprocess.run(
        ["git", "tag", "--list"], capture_output=True, text=True, check=True
    )
    return [t for t in out.stdout.splitlines() if t.strip()]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--prefix", required=True)
    p.add_argument("--date", required=True, help="YYYY.MM.DD")
    args = p.parse_args()
    print(next_tag(args.prefix, args.date, _git_tags()))


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4 : Lancer le test pour le voir passer**

```bash
cd <INFRA>/scripts/release && python3 -m pytest test_calver.py -v
```
Attendu : 5 passed.

- [ ] **Step 5 : Commit**

```bash
cd <INFRA>
git add scripts/release/calver.py scripts/release/test_calver.py
git commit -m "feat(release): add CalVer next-tag computation with tests"
```

### Task 1.4 : Script manifeste — mise à jour atomique (TDD)

**Files:**
- Create: `<INFRA>/scripts/release/manifest.py`
- Test: `<INFRA>/scripts/release/test_manifest.py`

Règle `platform_version` (`YYYY.MM.N`) : si le mois courant == mois du `platform_version` existant, incrémenter `N` ; sinon repartir à `N=1`.

- [ ] **Step 1 : Écrire le test qui échoue**

```python
# <INFRA>/scripts/release/test_manifest.py
import textwrap
import yaml
from manifest import update_manifest

BASE = textwrap.dedent("""\
    platform_version: "2026.06.0"
    updated_at: "2026-06-04T00:00:00Z"
    apps:
      notom-cloud-gateway: "pre-versioning"
      notom-connect-analytics: "pre-versioning"
      notom-data-platform: "pre-versioning"
""")

def _load(s):
    return yaml.safe_load(s)

def test_sets_app_version():
    out = update_manifest(BASE, "notom-connect-analytics", "analytics-2026.06.04",
                          now_iso="2026-06-04T17:30:00Z", now_month="2026.06")
    assert _load(out)["apps"]["notom-connect-analytics"] == "analytics-2026.06.04"

def test_other_apps_untouched():
    out = update_manifest(BASE, "notom-connect-analytics", "analytics-2026.06.04",
                          now_iso="2026-06-04T17:30:00Z", now_month="2026.06")
    assert _load(out)["apps"]["notom-data-platform"] == "pre-versioning"

def test_increments_platform_version_same_month():
    # 2026.06.0 -> 2026.06.1 (même mois)
    out = update_manifest(BASE, "notom-data-platform", "data-platform-2026.06.04",
                          now_iso="2026-06-04T17:30:00Z", now_month="2026.06")
    assert _load(out)["platform_version"] == "2026.06.1"

def test_resets_platform_version_new_month():
    out = update_manifest(BASE, "notom-data-platform", "data-platform-2026.07.01",
                          now_iso="2026-07-01T09:00:00Z", now_month="2026.07")
    assert _load(out)["platform_version"] == "2026.07.1"

def test_updates_timestamp():
    out = update_manifest(BASE, "notom-data-platform", "data-platform-2026.06.04",
                          now_iso="2026-06-04T17:30:00Z", now_month="2026.06")
    assert _load(out)["updated_at"] == "2026-06-04T17:30:00Z"
```

- [ ] **Step 2 : Lancer le test pour le voir échouer**

```bash
cd <INFRA>/scripts/release && python3 -m pip install pyyaml --quiet && python3 -m pytest test_manifest.py -v
```
Attendu : FAIL (`ModuleNotFoundError: No module named 'manifest'`).

- [ ] **Step 3 : Implémenter `manifest.py`**

```python
# <INFRA>/scripts/release/manifest.py
"""Met à jour prod-versions.yaml : version d'une app + platform_version + timestamp."""
import argparse
import datetime
import sys
import yaml


def _next_platform_version(current, now_month):
    # current au format "YYYY.MM.N"
    parts = (current or "").split(".")
    cur_month = ".".join(parts[:2]) if len(parts) >= 2 else ""
    cur_n = int(parts[2]) if len(parts) == 3 and parts[2].isdigit() else 0
    n = cur_n + 1 if cur_month == now_month else 1
    return f"{now_month}.{n}"


def update_manifest(content, app_key, app_version, now_iso, now_month):
    data = yaml.safe_load(content) or {}
    data.setdefault("apps", {})
    if app_key not in data["apps"]:
        raise KeyError(f"app inconnue dans le manifeste : {app_key}")
    data["apps"][app_key] = app_version
    data["platform_version"] = _next_platform_version(
        data.get("platform_version", ""), now_month
    )
    data["updated_at"] = now_iso
    return yaml.safe_dump(data, sort_keys=True, default_flow_style=False)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--manifest", required=True)
    p.add_argument("--app", required=True)
    p.add_argument("--version", required=True)
    args = p.parse_args()
    now = datetime.datetime.now(datetime.timezone.utc)
    now_iso = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    now_month = now.strftime("%Y.%m")
    with open(args.manifest) as f:
        content = f.read()
    out = update_manifest(content, args.app, args.version, now_iso, now_month)
    with open(args.manifest, "w") as f:
        f.write(out)
    print(f"manifest mis à jour : {args.app} = {args.version}")


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4 : Lancer le test pour le voir passer**

```bash
cd <INFRA>/scripts/release && python3 -m pytest test_manifest.py -v
```
Attendu : 5 passed.

- [ ] **Step 5 : Ajouter les dépendances + doc**

```bash
cd <INFRA>/scripts/release
printf 'pyyaml>=6\n' > requirements.txt
printf 'pytest>=8\n' > requirements-dev.txt
```

Create `<INFRA>/scripts/release/README.md` :
```markdown
# Release tooling

- `calver.py --prefix <p> --date YYYY.MM.DD` → imprime le prochain tag CalVer (lit `git tag`).
- `manifest.py --manifest <path> --app <key> --version <tag>` → met à jour `prod-versions.yaml`.

Appelés par la CD prod de chaque app (voir `.github/workflows/deploy-prod.yml`).
Tests : `python3 -m pip install -r requirements-dev.txt && python3 -m pytest`.
```

- [ ] **Step 6 : Commit + PR**

```bash
cd <INFRA>
git add scripts/release/manifest.py scripts/release/test_manifest.py \
        scripts/release/requirements.txt scripts/release/requirements-dev.txt \
        scripts/release/README.md
git commit -m "feat(release): add manifest updater with tests + tooling docs"
git push -u origin feat/release-tooling
gh pr create --repo notomio/notom-data-infra --base main --head feat/release-tooling \
  --title "feat(release): manifest + CalVer tooling" \
  --body "Fondation versioning : prod-versions.yaml + scripts/release (calver, manifest) testés."
```
Attendu : PR créée. **Merger après revue** (squash ou merge selon convention).

---

## Phase 2 — Pilote end-to-end : `notom-connect-analytics`

On déroule TOUT le workflow sur un seul repo d'abord pour valider, avant de répliquer.

### Task 2.1 : Créer la branche d'intégration `dev`

- [ ] **Step 1 : Créer `dev` depuis `main`**

```bash
cd <ANALYTICS>
git checkout main && git pull
git checkout -b dev && git push -u origin dev
```
Attendu : branche `dev` poussée sur `origin`.

### Task 2.2 : Protéger `main` (passage par PR obligatoire)

- [ ] **Step 1 : Appliquer la protection de branche sur `main`**

```bash
gh api -X PUT repos/notomio/notom-connect-analytics/branches/main/protection \
  -H "Accept: application/vnd.github+json" \
  -F "required_pull_request_reviews[required_approving_review_count]=0" \
  -F "required_status_checks=null" \
  -F "enforce_admins=false" \
  -F "restrictions=null" \
  -F "allow_force_pushes=false" \
  -F "allow_deletions=false"
```
> Note : `required_approving_review_count=0` permet l'auto-merge de la PR de release par toi seul (équipe solo) tout en bloquant le **push direct**. Monter à 1 si revue par pair souhaitée plus tard.

- [ ] **Step 2 : Vérifier**

```bash
gh api repos/notomio/notom-connect-analytics/branches/main/protection \
  --jq '{pr_required: (.required_pull_request_reviews != null), force_push: .allow_force_pushes.enabled}'
```
Attendu : `{"pr_required": true, "force_push": false}`.

### Task 2.3 : Garde-fou d'approbation sur l'environnement `production`

- [ ] **Step 1 : Exiger une approbation manuelle avant tout déploiement prod**

```bash
# Récupérer ton user id
MY_ID=$(gh api user --jq '.id')
gh api -X PUT repos/notomio/notom-connect-analytics/environments/production \
  -H "Accept: application/vnd.github+json" \
  -F "wait_timer=0" \
  -F "reviewers[][type]=User" \
  -F "reviewers[][id]=${MY_ID}" \
  -F "deployment_branch_policy=null"
```

- [ ] **Step 2 : Vérifier**

```bash
gh api repos/notomio/notom-connect-analytics/environments/production \
  --jq '.protection_rules[].type'
```
Attendu : contient `required_reviewers`.

### Task 2.4 : Mettre à niveau `deploy-prod.yml` (tag + manifeste + rollback)

**Files:**
- Modify: `<ANALYTICS>/.github/workflows/deploy-prod.yml`

On travaille sur une branche `feat/release-cd` de `<ANALYTICS>`.

- [ ] **Step 1 : Brancher**

```bash
cd <ANALYTICS>
git checkout dev && git pull
git checkout -b feat/release-cd
```

- [ ] **Step 2 : Remplacer le workflow par la version à niveau**

Remplacer intégralement `<ANALYTICS>/.github/workflows/deploy-prod.yml` par :

```yaml
# Trigger : push sur main (= merge d'une release PR) → déploie + tag CalVer + maj manifeste.
# Rollback : workflow_dispatch avec input "ref" (un tag antérieur) → redéploie ce tag, sans re-tagger.
name: Deploy to prod

on:
  push:
    branches: [main]
  workflow_dispatch:
    inputs:
      ref:
        description: "Tag à redéployer (rollback). Vide = dernier main."
        required: false
        default: ""

concurrency:
  group: deploy-prod
  cancel-in-progress: false

env:
  TARGET_DIR: /opt/superset
  COMPOSE_FILE: docker-compose-prod.yml
  SCW_SECRET_NAME: connect-analytics-env-prod
  APP_KEY: notom-connect-analytics
  TAG_PREFIX: analytics

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: production
    outputs:
      deployed_ref: ${{ steps.resolve.outputs.ref }}
      is_rollback: ${{ steps.resolve.outputs.is_rollback }}
    steps:
      - name: Resolve ref to deploy
        id: resolve
        run: |
          if [ -n "${{ github.event.inputs.ref }}" ]; then
            echo "ref=${{ github.event.inputs.ref }}" >> "$GITHUB_OUTPUT"
            echo "is_rollback=true" >> "$GITHUB_OUTPUT"
          else
            echo "ref=${{ github.sha }}" >> "$GITHUB_OUTPUT"
            echo "is_rollback=false" >> "$GITHUB_OUTPUT"
          fi

      - name: Checkout (ref résolu)
        uses: actions/checkout@v4
        with:
          ref: ${{ steps.resolve.outputs.ref }}
          fetch-depth: 0

      - name: Setup SSH key + known_hosts
        env:
          DEPLOY_KEY: ${{ secrets.NOTOM_DATA_SCW_GHA_DEPLOY_KEY }}
          BASTION_IP: ${{ vars.SCW_BASTION_IP }}
          BASTION_PORT: ${{ vars.SCW_BASTION_PORT }}
        run: |
          mkdir -p ~/.ssh
          printf '%s\n' "$DEPLOY_KEY" > ~/.ssh/id_ed25519
          chmod 600 ~/.ssh/id_ed25519
          ssh-keyscan -p "$BASTION_PORT" -H "$BASTION_IP" >> ~/.ssh/known_hosts 2>/dev/null

      - name: Install Scaleway CLI
        run: |
          curl -fsSL https://raw.githubusercontent.com/scaleway/scaleway-cli/master/scripts/get.sh | sh
          scw version

      - name: Fetch .env from Scaleway Secret Manager
        env:
          SCW_ACCESS_KEY: ${{ secrets.SCW_GHA_READ_ACCESS_KEY }}
          SCW_SECRET_KEY: ${{ secrets.SCW_GHA_READ_SECRET_KEY }}
          SCW_DEFAULT_PROJECT_ID: ${{ vars.SCW_PROD_PROJECT_ID }}
          SCW_DEFAULT_REGION: fr-par
          SCW_DEFAULT_ORGANIZATION_ID: 4bd21d20-c1fd-4778-8d05-c8d6fb935cab
        run: |
          scw secret version access-by-path secret-name=${SCW_SECRET_NAME} secret-path=/ revision=latest_enabled -o json \
            | jq -r '.data' | base64 -d | base64 -d > .env
          if [ ! -s .env ]; then
            echo "::error::.env vide après fetch — secret ${SCW_SECRET_NAME} inaccessible"
            exit 1
          fi
          mkdir -p docker
          cp .env docker/.env
          echo "✓ .env matérialisé ($(wc -l < .env) lignes) + copié dans docker/.env"

      - name: Rsync code + .env to VM (via bastion ProxyJump)
        env:
          BASTION_IP: ${{ vars.SCW_BASTION_IP }}
          BASTION_PORT: ${{ vars.SCW_BASTION_PORT }}
          VM_IP: ${{ vars.SCW_VM_PRIVATE_IP }}
        run: |
          rsync -avz --delete \
            --exclude '.git' --exclude '.github' --exclude 'node_modules' \
            -e "ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=~/.ssh/known_hosts -i ~/.ssh/id_ed25519 -J bastion@${BASTION_IP}:${BASTION_PORT}" \
            ./ root@${VM_IP}:${TARGET_DIR}/

      - name: docker compose up on VM
        env:
          BASTION_IP: ${{ vars.SCW_BASTION_IP }}
          BASTION_PORT: ${{ vars.SCW_BASTION_PORT }}
          VM_IP: ${{ vars.SCW_VM_PRIVATE_IP }}
        run: |
          ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=~/.ssh/known_hosts -i ~/.ssh/id_ed25519 \
              -J bastion@${BASTION_IP}:${BASTION_PORT} \
              root@${VM_IP} \
              "cd ${TARGET_DIR} && docker compose -f ${COMPOSE_FILE} pull && docker compose -f ${COMPOSE_FILE} up -d --remove-orphans"

  finalize:
    needs: deploy
    if: needs.deploy.outputs.is_rollback == 'false'
    runs-on: ubuntu-latest
    env:
      APP_KEY: notom-connect-analytics
      TAG_PREFIX: analytics
    steps:
      - name: Checkout app repo (pour git tag)
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Checkout infra repo (scripts + manifeste)
        uses: actions/checkout@v4
        with:
          repository: notomio/notom-data-infra
          token: ${{ secrets.NOTOM_MANIFEST_WRITE_TOKEN }}
          path: _infra
          fetch-depth: 0

      - name: Setup Python
        uses: actions/setup-python@v5
        with:
          python-version: "3.11"

      - name: Install deps
        run: python -m pip install -r _infra/scripts/release/requirements.txt

      - name: Compute CalVer tag
        id: tag
        run: |
          DATE=$(date -u +%Y.%m.%d)
          TAG=$(python _infra/scripts/release/calver.py --prefix "${TAG_PREFIX}" --date "${DATE}")
          echo "tag=${TAG}" >> "$GITHUB_OUTPUT"
          echo "Tag calculé : ${TAG}"

      - name: Create + push tag on app repo
        run: |
          git tag "${{ steps.tag.outputs.tag }}" "${{ github.sha }}"
          git push origin "${{ steps.tag.outputs.tag }}"

      - name: Update global manifest
        run: |
          python _infra/scripts/release/manifest.py \
            --manifest _infra/prod-versions.yaml \
            --app "${APP_KEY}" \
            --version "${{ steps.tag.outputs.tag }}"

      - name: Commit + push manifest to infra
        run: |
          cd _infra
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add prod-versions.yaml
          git commit -m "chore(release): ${APP_KEY} = ${{ steps.tag.outputs.tag }}" || { echo "rien à committer"; exit 0; }
          git push origin HEAD:main
```

- [ ] **Step 3 : Valider la syntaxe du workflow**

```bash
cd <ANALYTICS>
# actionlint via docker (pas d'install locale requise)
docker run --rm -v "$PWD":/repo --workdir /repo rhysd/actionlint:latest -color .github/workflows/deploy-prod.yml
```
Attendu : aucune erreur (exit 0). Si docker indispo : `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/deploy-prod.yml'))"` (valide au moins le YAML).

- [ ] **Step 4 : Commit + PR vers `dev` puis release vers `main`**

```bash
cd <ANALYTICS>
git add .github/workflows/deploy-prod.yml
git commit -m "feat(ci): deploy by tag + CalVer tagging + manifest update + rollback input"
git push -u origin feat/release-cd
gh pr create --repo notomio/notom-connect-analytics --base dev --head feat/release-cd \
  --title "feat(ci): release CD (tag + manifest + rollback)" \
  --body "Met à niveau la CD prod : déploiement par tag, tag CalVer auto, maj manifeste global, input rollback."
```
Attendu : PR `feat/release-cd → dev` créée. **Merger dans `dev`.**

> ⚠️ Le workflow ne se déclenche en prod que sur `push main`. La validation réelle (Task 2.5) se fait via la **release PR `dev → main`**, donc pendant une fenêtre acceptable.

### Task 2.5 : Validation réelle (release + rollback)

> Nécessite une **fenêtre de déploiement** (touche la prod analytics réelle). À faire quand un déploiement prod est acceptable.

- [ ] **Step 1 : Ouvrir et merger la release PR `dev → main`**

```bash
cd <ANALYTICS>
gh pr create --repo notomio/notom-connect-analytics --base main --head dev \
  --title "release: analytics $(date -u +%Y.%m.%d)" \
  --body "Première release via le nouveau workflow. PR embarquées : voir diff dev..main."
# Merger via l'UI ou :
gh pr merge --repo notomio/notom-connect-analytics --merge --admin
```

- [ ] **Step 2 : Approuver le déploiement prod**

Aller dans Actions → run "Deploy to prod" en attente → **Review deployments** → approuver l'environnement `production`.

- [ ] **Step 3 : Vérifier le résultat**

```bash
cd <ANALYTICS>
git fetch --tags
git tag --list "analytics-*"                 # attendu : analytics-YYYY.MM.DD
gh run list --repo notomio/notom-connect-analytics --workflow deploy-prod.yml -L 1
```
Vérifier aussi côté infra :
```bash
cd <INFRA> && git checkout main && git pull
grep -A4 'apps:' prod-versions.yaml          # notom-connect-analytics = analytics-YYYY.MM.DD
grep 'platform_version' prod-versions.yaml   # incrémenté (ex. 2026.06.1)
```
Et vérifier que l'app répond (domaine analytics prod).

- [ ] **Step 4 : Tester le rollback**

```bash
# Lister les tags disponibles
git tag --list "analytics-*"
# Redéployer un tag (rollback). Si un seul tag existe, ce step valide le MÉCANISME.
gh workflow run deploy-prod.yml --repo notomio/notom-connect-analytics \
  -f ref="analytics-YYYY.MM.DD"
```
Approuver le déploiement. Attendu : le run "Deploy to prod" redéploie le tag, et le job `finalize` est **sauté** (`if: is_rollback == 'false'`) → aucun nouveau tag, manifeste inchangé.

---

## Phase 3 — Réplication sur les 2 autres repos

Même structure que la Phase 2 (Tasks 2.1 → 2.4), avec les différences de déploiement propres à chaque repo. La validation réelle (équivalent 2.5) se fait à la prochaine release naturelle de chaque app.

### Task 3.1 : `notom-data-platform`

- [ ] **Step 1 : Branche `dev` (déjà existante) — vérifier/aligner**

```bash
cd <DP>
git fetch origin
git checkout dev 2>/dev/null || git checkout -b dev origin/main
git merge origin/main --ff-only 2>/dev/null || true
git push -u origin dev
```

- [ ] **Step 2 : Protection `main` + environnement `production`**

```bash
gh api -X PUT repos/notomio/notom-data-platform/branches/main/protection \
  -H "Accept: application/vnd.github+json" \
  -F "required_pull_request_reviews[required_approving_review_count]=0" \
  -F "required_status_checks=null" -F "enforce_admins=false" \
  -F "restrictions=null" -F "allow_force_pushes=false" -F "allow_deletions=false"

MY_ID=$(gh api user --jq '.id')
gh api -X PUT repos/notomio/notom-data-platform/environments/production \
  -H "Accept: application/vnd.github+json" \
  -F "wait_timer=0" -F "reviewers[][type]=User" -F "reviewers[][id]=${MY_ID}" \
  -F "deployment_branch_policy=null"
```

- [ ] **Step 3 : Mettre à niveau `deploy-prod.yml`**

Brancher (`git checkout dev && git pull && git checkout -b feat/release-cd`), puis remplacer `<DP>/.github/workflows/deploy-prod.yml` par :

```yaml
# Trigger : push main → déploie + tag CalVer + manifeste. Rollback : workflow_dispatch input "ref".
name: Deploy to prod

on:
  push:
    branches: [main]
  workflow_dispatch:
    inputs:
      ref:
        description: "Tag à redéployer (rollback). Vide = dernier main."
        required: false
        default: ""

concurrency:
  group: deploy-prod
  cancel-in-progress: false

env:
  TARGET_DIR: /opt/notom-data-platform
  COMPOSE_FILE: docker-compose.yaml
  SCW_SECRET_NAME: data-platform-env-prod
  APP_KEY: notom-data-platform
  TAG_PREFIX: data-platform

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: production
    outputs:
      is_rollback: ${{ steps.resolve.outputs.is_rollback }}
    steps:
      - name: Resolve ref to deploy
        id: resolve
        run: |
          if [ -n "${{ github.event.inputs.ref }}" ]; then
            echo "ref=${{ github.event.inputs.ref }}" >> "$GITHUB_OUTPUT"
            echo "is_rollback=true" >> "$GITHUB_OUTPUT"
          else
            echo "ref=${{ github.sha }}" >> "$GITHUB_OUTPUT"
            echo "is_rollback=false" >> "$GITHUB_OUTPUT"
          fi

      - name: Checkout (ref résolu)
        uses: actions/checkout@v4
        with:
          ref: ${{ steps.resolve.outputs.ref }}
          fetch-depth: 0

      - name: Setup SSH key + known_hosts
        env:
          DEPLOY_KEY: ${{ secrets.NOTOM_DATA_SCW_GHA_DEPLOY_KEY }}
          BASTION_IP: ${{ vars.SCW_BASTION_IP }}
          BASTION_PORT: ${{ vars.SCW_BASTION_PORT }}
        run: |
          mkdir -p ~/.ssh
          printf '%s\n' "$DEPLOY_KEY" > ~/.ssh/id_ed25519
          chmod 600 ~/.ssh/id_ed25519
          ssh-keyscan -p "$BASTION_PORT" -H "$BASTION_IP" >> ~/.ssh/known_hosts 2>/dev/null

      - name: Install Scaleway CLI
        run: |
          curl -fsSL https://raw.githubusercontent.com/scaleway/scaleway-cli/master/scripts/get.sh | sh
          scw version

      - name: Fetch .env from Scaleway Secret Manager
        env:
          SCW_ACCESS_KEY: ${{ secrets.SCW_GHA_READ_ACCESS_KEY }}
          SCW_SECRET_KEY: ${{ secrets.SCW_GHA_READ_SECRET_KEY }}
          SCW_DEFAULT_PROJECT_ID: ${{ vars.SCW_PROD_PROJECT_ID }}
          SCW_DEFAULT_REGION: fr-par
          SCW_DEFAULT_ORGANIZATION_ID: 4bd21d20-c1fd-4778-8d05-c8d6fb935cab
        run: |
          scw secret version access-by-path secret-name=${SCW_SECRET_NAME} secret-path=/ revision=latest_enabled -o json \
            | jq -r '.data' | base64 -d | base64 -d > .env
          if [ ! -s .env ]; then
            echo "::error::.env vide après fetch — secret ${SCW_SECRET_NAME} inaccessible"
            exit 1
          fi
          echo "✓ .env matérialisé ($(wc -l < .env) lignes)"

      - name: Rsync code + .env to VM (via bastion ProxyJump)
        env:
          BASTION_IP: ${{ vars.SCW_BASTION_IP }}
          BASTION_PORT: ${{ vars.SCW_BASTION_PORT }}
          VM_IP: ${{ vars.SCW_VM_PRIVATE_IP }}
        run: |
          rsync -avz --delete \
            --exclude '.git' --exclude '.github' --exclude 'node_modules' \
            -e "ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=~/.ssh/known_hosts -i ~/.ssh/id_ed25519 -J bastion@${BASTION_IP}:${BASTION_PORT}" \
            ./ root@${VM_IP}:${TARGET_DIR}/

      - name: Fix volume mount ownership for airflow UID (50000)
        env:
          BASTION_IP: ${{ vars.SCW_BASTION_IP }}
          BASTION_PORT: ${{ vars.SCW_BASTION_PORT }}
          VM_IP: ${{ vars.SCW_VM_PRIVATE_IP }}
        run: |
          ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=~/.ssh/known_hosts -i ~/.ssh/id_ed25519 \
              -J bastion@${BASTION_IP}:${BASTION_PORT} \
              root@${VM_IP} \
              "mkdir -p ${TARGET_DIR}/logs ${TARGET_DIR}/secrets && chown -R 50000:0 ${TARGET_DIR}/logs ${TARGET_DIR}/secrets"

      - name: docker compose up on VM
        env:
          BASTION_IP: ${{ vars.SCW_BASTION_IP }}
          BASTION_PORT: ${{ vars.SCW_BASTION_PORT }}
          VM_IP: ${{ vars.SCW_VM_PRIVATE_IP }}
        run: |
          ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=~/.ssh/known_hosts -i ~/.ssh/id_ed25519 \
              -J bastion@${BASTION_IP}:${BASTION_PORT} \
              root@${VM_IP} \
              "cd ${TARGET_DIR} && docker compose -f ${COMPOSE_FILE} pull && docker compose -f ${COMPOSE_FILE} up -d --remove-orphans"

  finalize:
    needs: deploy
    if: needs.deploy.outputs.is_rollback == 'false'
    runs-on: ubuntu-latest
    env:
      APP_KEY: notom-data-platform
      TAG_PREFIX: data-platform
    steps:
      - name: Checkout app repo (pour git tag)
        uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Checkout infra repo (scripts + manifeste)
        uses: actions/checkout@v4
        with:
          repository: notomio/notom-data-infra
          token: ${{ secrets.NOTOM_MANIFEST_WRITE_TOKEN }}
          path: _infra
          fetch-depth: 0
      - name: Setup Python
        uses: actions/setup-python@v5
        with:
          python-version: "3.11"
      - name: Install deps
        run: python -m pip install -r _infra/scripts/release/requirements.txt
      - name: Compute CalVer tag
        id: tag
        run: |
          DATE=$(date -u +%Y.%m.%d)
          TAG=$(python _infra/scripts/release/calver.py --prefix "${TAG_PREFIX}" --date "${DATE}")
          echo "tag=${TAG}" >> "$GITHUB_OUTPUT"
      - name: Create + push tag on app repo
        run: |
          git tag "${{ steps.tag.outputs.tag }}" "${{ github.sha }}"
          git push origin "${{ steps.tag.outputs.tag }}"
      - name: Update global manifest
        run: |
          python _infra/scripts/release/manifest.py \
            --manifest _infra/prod-versions.yaml --app "${APP_KEY}" --version "${{ steps.tag.outputs.tag }}"
      - name: Commit + push manifest to infra
        run: |
          cd _infra
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add prod-versions.yaml
          git commit -m "chore(release): ${APP_KEY} = ${{ steps.tag.outputs.tag }}" || { echo "rien à committer"; exit 0; }
          git push origin HEAD:main
```

- [ ] **Step 4 : Valider la syntaxe + commit + PR vers `dev`**

```bash
cd <DP>
docker run --rm -v "$PWD":/repo --workdir /repo rhysd/actionlint:latest -color .github/workflows/deploy-prod.yml
git add .github/workflows/deploy-prod.yml
git commit -m "feat(ci): deploy by tag + CalVer + manifest + rollback"
git push -u origin feat/release-cd
gh pr create --repo notomio/notom-data-platform --base dev --head feat/release-cd \
  --title "feat(ci): release CD (tag + manifest + rollback)" --body "Idem analytics, adapté data-platform (chown UID 50000 conservé)."
```
Attendu : actionlint OK, PR créée. Merger dans `dev`.

### Task 3.2 : `notom-cloud-gateway`

- [ ] **Step 1 : Branche `dev` + protections + environnement**

```bash
cd <GW>
git checkout main && git pull
git checkout -b dev && git push -u origin dev

gh api -X PUT repos/notomio/notom-cloud-gateway/branches/main/protection \
  -H "Accept: application/vnd.github+json" \
  -F "required_pull_request_reviews[required_approving_review_count]=0" \
  -F "required_status_checks=null" -F "enforce_admins=false" \
  -F "restrictions=null" -F "allow_force_pushes=false" -F "allow_deletions=false"

MY_ID=$(gh api user --jq '.id')
gh api -X PUT repos/notomio/notom-cloud-gateway/environments/production \
  -H "Accept: application/vnd.github+json" \
  -F "wait_timer=0" -F "reviewers[][type]=User" -F "reviewers[][id]=${MY_ID}" \
  -F "deployment_branch_policy=null"
```

- [ ] **Step 2 : Mettre à niveau `deploy-prod.yml` (conserve le rendu de template + IP publique directe)**

Brancher puis remplacer `<GW>/.github/workflows/deploy-prod.yml` par :

```yaml
# Trigger : push main → render template + déploie + tag CalVer + manifeste. Rollback : input "ref".
name: Deploy to prod

on:
  push:
    branches: [main]
  workflow_dispatch:
    inputs:
      ref:
        description: "Tag à redéployer (rollback). Vide = dernier main."
        required: false
        default: ""

concurrency:
  group: deploy-prod
  cancel-in-progress: false

env:
  TARGET_DIR: /opt/traefik
  COMPOSE_FILE: docker-compose.yml
  SCW_SECRET_NAME: cloud-gateway-env-prod
  APP_KEY: notom-cloud-gateway
  TAG_PREFIX: gateway

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: production
    outputs:
      is_rollback: ${{ steps.resolve.outputs.is_rollback }}
    steps:
      - name: Resolve ref to deploy
        id: resolve
        run: |
          if [ -n "${{ github.event.inputs.ref }}" ]; then
            echo "ref=${{ github.event.inputs.ref }}" >> "$GITHUB_OUTPUT"
            echo "is_rollback=true" >> "$GITHUB_OUTPUT"
          else
            echo "ref=${{ github.sha }}" >> "$GITHUB_OUTPUT"
            echo "is_rollback=false" >> "$GITHUB_OUTPUT"
          fi

      - name: Checkout (ref résolu)
        uses: actions/checkout@v4
        with:
          ref: ${{ steps.resolve.outputs.ref }}
          fetch-depth: 0

      - name: Setup SSH key + known_hosts
        env:
          DEPLOY_KEY: ${{ secrets.NOTOM_DATA_SCW_GHA_DEPLOY_KEY }}
          VM_IP: ${{ vars.SCW_VM_PUBLIC_IP }}
        run: |
          mkdir -p ~/.ssh
          printf '%s\n' "$DEPLOY_KEY" > ~/.ssh/id_ed25519
          chmod 600 ~/.ssh/id_ed25519
          ssh-keyscan -H "$VM_IP" >> ~/.ssh/known_hosts 2>/dev/null

      - name: Install Scaleway CLI
        run: |
          curl -fsSL https://raw.githubusercontent.com/scaleway/scaleway-cli/master/scripts/get.sh | sh
          scw version

      - name: Fetch .env from Scaleway Secret Manager
        env:
          SCW_ACCESS_KEY: ${{ secrets.SCW_GHA_READ_ACCESS_KEY }}
          SCW_SECRET_KEY: ${{ secrets.SCW_GHA_READ_SECRET_KEY }}
          SCW_DEFAULT_PROJECT_ID: ${{ vars.SCW_PROD_PROJECT_ID }}
          SCW_DEFAULT_REGION: fr-par
          SCW_DEFAULT_ORGANIZATION_ID: 4bd21d20-c1fd-4778-8d05-c8d6fb935cab
        run: |
          scw secret version access-by-path secret-name=${SCW_SECRET_NAME} secret-path=/ revision=latest_enabled -o json \
            | jq -r '.data' | base64 -d | base64 -d > .env
          if [ ! -s .env ]; then
            echo "::error::.env vide après fetch — secret ${SCW_SECRET_NAME} inaccessible"
            exit 1
          fi
          echo "✓ .env matérialisé ($(wc -l < .env) lignes)"

      - name: Render Traefik dynamic config from template
        env:
          SUPERSET_BACKEND_URL: ${{ vars.SUPERSET_BACKEND_URL }}
          AIRFLOW_BACKEND_URL: ${{ vars.AIRFLOW_BACKEND_URL }}
          ANALYTICS_DOMAIN: ${{ vars.ANALYTICS_DOMAIN }}
          DATA_DOMAIN: ${{ vars.DATA_DOMAIN }}
          AUTHENTIK_DOMAIN: ${{ vars.AUTHENTIK_DOMAIN }}
        run: |
          set -euo pipefail
          : "${SUPERSET_BACKEND_URL:?missing GH env var}"
          : "${AIRFLOW_BACKEND_URL:?missing GH env var}"
          : "${ANALYTICS_DOMAIN:?missing GH env var}"
          : "${DATA_DOMAIN:?missing GH env var}"
          : "${AUTHENTIK_DOMAIN:?missing GH env var}"
          envsubst < traefik/dynamic/services.yml.template > traefik/dynamic/services.yml
          if grep -E '\$\{[A-Z_]+\}' traefik/dynamic/services.yml; then
            echo "::error::placeholders non-résolus dans services.yml"
            exit 1
          fi
          echo "✓ services.yml rendu pour env=production"

      - name: Rsync code + .env to VM (IP publique directe)
        env:
          VM_IP: ${{ vars.SCW_VM_PUBLIC_IP }}
        run: |
          rsync -avz --delete \
            --exclude '.git' --exclude '.github' --exclude 'node_modules' --exclude '*.template' \
            -e "ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=~/.ssh/known_hosts -i ~/.ssh/id_ed25519" \
            ./ root@${VM_IP}:${TARGET_DIR}/

      - name: docker compose up on VM
        env:
          VM_IP: ${{ vars.SCW_VM_PUBLIC_IP }}
        run: |
          ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=~/.ssh/known_hosts -i ~/.ssh/id_ed25519 \
              root@${VM_IP} \
              "cd ${TARGET_DIR} && docker compose -f ${COMPOSE_FILE} pull && docker compose -f ${COMPOSE_FILE} up -d --remove-orphans"

  finalize:
    needs: deploy
    if: needs.deploy.outputs.is_rollback == 'false'
    runs-on: ubuntu-latest
    env:
      APP_KEY: notom-cloud-gateway
      TAG_PREFIX: gateway
    steps:
      - name: Checkout app repo (pour git tag)
        uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Checkout infra repo (scripts + manifeste)
        uses: actions/checkout@v4
        with:
          repository: notomio/notom-data-infra
          token: ${{ secrets.NOTOM_MANIFEST_WRITE_TOKEN }}
          path: _infra
          fetch-depth: 0
      - name: Setup Python
        uses: actions/setup-python@v5
        with:
          python-version: "3.11"
      - name: Install deps
        run: python -m pip install -r _infra/scripts/release/requirements.txt
      - name: Compute CalVer tag
        id: tag
        run: |
          DATE=$(date -u +%Y.%m.%d)
          TAG=$(python _infra/scripts/release/calver.py --prefix "${TAG_PREFIX}" --date "${DATE}")
          echo "tag=${TAG}" >> "$GITHUB_OUTPUT"
      - name: Create + push tag on app repo
        run: |
          git tag "${{ steps.tag.outputs.tag }}" "${{ github.sha }}"
          git push origin "${{ steps.tag.outputs.tag }}"
      - name: Update global manifest
        run: |
          python _infra/scripts/release/manifest.py \
            --manifest _infra/prod-versions.yaml --app "${APP_KEY}" --version "${{ steps.tag.outputs.tag }}"
      - name: Commit + push manifest to infra
        run: |
          cd _infra
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add prod-versions.yaml
          git commit -m "chore(release): ${APP_KEY} = ${{ steps.tag.outputs.tag }}" || { echo "rien à committer"; exit 0; }
          git push origin HEAD:main
```

- [ ] **Step 3 : Valider syntaxe + commit + PR vers `dev`**

```bash
cd <GW>
docker run --rm -v "$PWD":/repo --workdir /repo rhysd/actionlint:latest -color .github/workflows/deploy-prod.yml
git add .github/workflows/deploy-prod.yml
git commit -m "feat(ci): deploy by tag + CalVer + manifest + rollback"
git push -u origin feat/release-cd
gh pr create --repo notomio/notom-cloud-gateway --base dev --head feat/release-cd \
  --title "feat(ci): release CD (tag + manifest + rollback)" --body "Idem, conserve le rendu de template Traefik + IP publique directe."
```
Attendu : actionlint OK, PR créée. Merger dans `dev`.

> Note : `deploy-dev.yml` (staging gateway, rsync) **reste inchangé** — le staging gateway n'est pas un poste de dev quotidien ; on n'y applique pas l'asymétrie git-pull.

---

## Phase 4 — Runbook de release

### Task 4.1 : Documenter la procédure release + rollback

**Files:**
- Create: `<racine workspace>/docs/RELEASE.md`

- [ ] **Step 1 : Écrire le runbook**

Create `docs/RELEASE.md` :
```markdown
# Runbook — Release & Rollback

## Faire une release (par app)
1. Les `feat/*` sont mergées dans `dev` (PR). `dev` tourne sur la VM staging.
2. Valider sur staging.
3. Ouvrir la PR `dev → main` (titre : `release: <app> YYYY.MM.DD`). GitHub liste les PR embarquées.
4. Merger la PR. La CD "Deploy to prod" démarre puis **attend une approbation** (environnement production).
5. Approuver dans Actions → Review deployments. La CD déploie, pose le tag `<prefix>-YYYY.MM.DD`, et met à jour `notom-data-infra/prod-versions.yaml` (+ `platform_version`).

Préfixes : gateway → `gateway-`, analytics → `analytics-`, data-platform → `data-platform-`.

## Rollback (revenir à une version)
1. Trouver le tag cible : `git tag --list "<prefix>-*"` ou l'historique de `prod-versions.yaml`.
2. Actions → "Deploy to prod" → Run workflow → renseigner `ref` = le tag cible.
3. Approuver. Le code/config du tag est redéployé ; aucun nouveau tag n'est posé (job `finalize` sauté).
   ⚠️ Le rollback ne restaure PAS les secrets (toujours la version courante du Secret Manager).

## Version prod actuelle
`notom-data-infra/prod-versions.yaml` → `platform_version` + version par app. L'historique git du
fichier donne l'état prod à n'importe quelle date.
```

- [ ] **Step 2 : (pas de commit ici)**

`docs/` à la racine du workspace n'est pas un repo git (emplacement neutre, destiné au futur repo `notom-dev`). Laisser le fichier non-commité ; il rejoindra `notom-dev` (projet #2) ou un repo de doc selon décision ultérieure.

---

## Auto-revue (faite)

**Couverture spec ↔ plan :**
- Branches `dev`/`main` (spec §4.1) → Tasks 2.1, 3.1, 3.2. ✓
- Asymétrie staging-mutable / prod-immuable (spec §4.2) → CD déploie un ref figé (Task 2.4 step "Checkout ref résolu") ; staging = git pull côté dev (hors CI, déjà en place), gateway staging laissé en rsync (note Task 3.2). ✓
- Release CalVer par app (spec §5.2) → `calver.py` (Task 1.3) + job `finalize` (Tasks 2.4/3.1/3.2). Préfixes figés respectés (`gateway`/`analytics`/`data-platform`). ✓
- Cadence indépendante + version globale (spec §5.3, §7) → `manifest.py` + `prod-versions.yaml` (Tasks 1.2/1.4) mis à jour par chaque app. ✓
- CD prod : déploie un tag, rollback, approbation (spec §6) → input `ref` + résolution (Task 2.4), env `production` + reviewer (Task 2.3/3.x), `concurrency` conservé. ✓
- Repo infra héberge le manifeste + scripts (spec §8) → Phase 1. ✓
- Secrets non versionnés + token inter-repo (spec §9) → Task 0.1 ; note rollback-hors-secrets dans le runbook. ✓

**Placeholders :** aucun `TODO`/`TBD` dans le code ou les commandes ; les seuls `…COLLER_ICI`/`YYYY.MM.DD` sont des valeurs runtime explicitement à renseigner par l'opérateur.

**Cohérence des types/noms :** `is_rollback`/`ref` (outputs) identiques entre `resolve`, `deploy`, `finalize` dans les 3 workflows ; `next_tag(prefix, date, existing)` et `update_manifest(content, app_key, app_version, now_iso, now_month)` appelés avec la même signature dans les tests et le `main()`. ✓

**Hors-scope confirmé (spec §11) :** pas de CI bloquante (Niveau 3), pas d'env local, pas de tests dbt lourds — non inclus. ✓
```
