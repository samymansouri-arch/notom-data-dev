# Release « tout » multi-app + note Slack — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Étendre le skill `notom-data-dev:release` avec un mode « tout » qui release en prod les apps ayant du nouveau (une confirmation récap unique) puis poste une note de release consolidée sur un canal Slack dédié.

**Architecture:** Orchestration **dans le skill** (approche A). Le skill calcule le périmètre des 3 repos, confirme une fois, lance séquentiellement chaque `deploy-prod.yml`, puis appelle un petit script Python `slack_note.py` (pur + testé) qui construit/poste la note. Le webhook du canal dédié vit dans un **secret Scaleway codifié en Terraform**.

**Tech Stack:** Bash + `gh` CLI (orchestration skill), Python 3 stdlib (`slack_note.py`, tests pytest), Terraform + provider Scaleway (secret webhook), `scw` CLI (lecture du webhook).

**Spec:** `notom-data-dev/docs/2026-06-18-release-all-slack-design.md`

---

## Prérequis (avant exécution)

- `notom-data-infra` : partir d'une branche **propre depuis `main` à jour** (le merge Toucan #20 est intégré). ⚠️ Si des changements `slack_webhook_url` (alertes data-platform) sont encore non commités dans le working tree, les committer/mettre de côté **avant** — ils sont hors de ce plan.
- `notom-data-dev` : travailler sur la branche `feat/release-all-slack` (déjà créée, contient la spec + ce plan).
- L'URL réelle du webhook du canal Slack dédié sera fournie par l'utilisateur au moment de remplir `envs/prod/terraform.tfvars` (Task 3, étape finale). Elle n'est PAS nécessaire pour coder/tester.

## File Structure

| Fichier | Repo | Responsabilité |
|---|---|---|
| `scripts/slack_note.py` | notom-data-dev | Construit (fonction pure `build_payload`) et poste la note consolidée. Stdlib only. |
| `scripts/test_slack_note.py` | notom-data-dev | Tests pytest de `build_payload` + smoke `--dry-run`. |
| `scripts/requirements-dev.txt` | notom-data-dev | `pytest` (dev). |
| `skills/release/SKILL.md` | notom-data-dev | Ajout de la section « Mode tout ». |
| `modules/data-stack/secrets.tf` | notom-data-infra | Ressource `scaleway_secret`/version `slack-release-webhook` (count si fourni). |
| `modules/data-stack/variables.tf` (ou `env-files.tf`) | notom-data-infra | Variable `slack_release_webhook_url`. |
| `envs/prod/{variables,main}.tf`, `terraform.tfvars.example` | notom-data-infra | Câblage prod du webhook. |

---

## Task 1: `slack_note.py` — fonction pure `build_payload`

**Files:**
- Create: `notom-data-dev/scripts/slack_note.py`
- Create: `notom-data-dev/scripts/test_slack_note.py`
- Create: `notom-data-dev/scripts/requirements-dev.txt`

- [ ] **Step 1: requirements-dev + test qui échoue**

`notom-data-dev/scripts/requirements-dev.txt` :
```
pytest>=8
```

`notom-data-dev/scripts/test_slack_note.py` :
```python
from slack_note import build_payload

BASE = {
    "platform_version": "2026.06.3",
    "date": "2026-06-18",
    "released": [
        {
            "app": "connect-analytics",
            "version": "analytics-2026.06.18",
            "changes": ["NUMI — Exploration Télémétrie (#15)", "dev-init staging (#14)"],
        },
        {
            "app": "data-platform",
            "version": "data-platform-2026.06.18",
            "changes": ["alertes Slack échec asset-triggered (#36)"],
        },
    ],
    "skipped": ["cloud-gateway"],
}


def test_header_has_platform_and_date():
    text = build_payload(BASE)["text"]
    assert text.splitlines()[0] == (
        "🚀 Release prod notom-data — platform 2026.06.3 — 2026-06-18"
    )


def test_app_line_with_pr_count():
    text = build_payload(BASE)["text"]
    assert "• connect-analytics → analytics-2026.06.18  (2 PR)" in text
    assert "• data-platform → data-platform-2026.06.18  (1 PR)" in text


def test_changes_are_bulleted():
    text = build_payload(BASE)["text"]
    assert "    – NUMI — Exploration Télémétrie (#15)" in text
    assert "    – dev-init staging (#14)" in text


def test_manifest_line_present():
    assert "manifest: prod-versions.yaml" in build_payload(BASE)["text"]


def test_skipped_footer_present():
    text = build_payload(BASE)["text"]
    assert "_(non releasées car déjà à jour : cloud-gateway)_" in text


def test_no_skipped_no_footer():
    text = build_payload(dict(BASE, skipped=[]))["text"]
    assert "non releasées" not in text
```

- [ ] **Step 2: Lancer le test → échoue**

Run: `cd notom-data-dev/scripts && python3 -m pip install -r requirements-dev.txt && python3 -m pytest test_slack_note.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'slack_note'`.

- [ ] **Step 3: Implémenter `build_payload`**

`notom-data-dev/scripts/slack_note.py` :
```python
#!/usr/bin/env python3
"""Construit (et poste) la note de release consolidée pour Slack.

Entrée : JSON décrivant la release (platform_version, date, released[], skipped[]).
"""


def build_payload(release):
    """release: dict. released[i] = {app, version, changes:[str]}.
    Retourne {"text": <mrkdwn Slack>}."""
    lines = [
        f"🚀 Release prod notom-data — platform "
        f"{release['platform_version']} — {release['date']}"
    ]
    for app in release["released"]:
        n = len(app["changes"])
        lines.append(f"• {app['app']} → {app['version']}  ({n} PR)")
        for change in app["changes"]:
            lines.append(f"    – {change}")
    lines.append("manifest: prod-versions.yaml")
    skipped = release.get("skipped") or []
    if skipped:
        lines.append(f"_(non releasées car déjà à jour : {', '.join(skipped)})_")
    return {"text": "\n".join(lines)}
```

- [ ] **Step 4: Lancer les tests → passent**

Run: `cd notom-data-dev/scripts && python3 -m pytest test_slack_note.py -v`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git -C notom-data-dev add scripts/slack_note.py scripts/test_slack_note.py scripts/requirements-dev.txt
git -C notom-data-dev commit -m "feat(release): build_payload — note Slack de release consolidée (TDD)"
```

---

## Task 2: `slack_note.py` — CLI (`--dry-run` / post)

**Files:**
- Modify: `notom-data-dev/scripts/slack_note.py` (ajout `post` + `main`)
- Modify: `notom-data-dev/scripts/test_slack_note.py` (smoke dry-run)

- [ ] **Step 1: Test dry-run qui échoue**

Ajouter à `notom-data-dev/scripts/test_slack_note.py` :
```python
import json
import subprocess
import sys


def test_cli_dry_run_prints_payload(tmp_path):
    fixture = tmp_path / "release.json"
    fixture.write_text(json.dumps(BASE), encoding="utf-8")
    out = subprocess.check_output(
        [sys.executable, "slack_note.py", "--input", str(fixture), "--dry-run"],
        text=True,
    )
    payload = json.loads(out)
    assert "platform 2026.06.3" in payload["text"]
    assert "• connect-analytics →" in payload["text"]
```

- [ ] **Step 2: Lancer → échoue**

Run: `cd notom-data-dev/scripts && python3 -m pytest test_slack_note.py::test_cli_dry_run_prints_payload -v`
Expected: FAIL — le script n'a pas d'entrée CLI (`--input` inconnu / pas de `__main__`), `CalledProcessError`.

- [ ] **Step 3: Ajouter `post` + `main`**

Ajouter en bas de `notom-data-dev/scripts/slack_note.py` :
```python
import argparse
import json
import sys
import urllib.request


def post(webhook_url, payload):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        webhook_url, data=data, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=15) as resp:  # noqa: S310
        return resp.status


def main(argv=None):
    parser = argparse.ArgumentParser(description="Poste la note de release Slack.")
    parser.add_argument("--input", default="-", help="Fichier JSON ('-' = stdin).")
    parser.add_argument("--webhook-url", default="")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    if args.input == "-":
        raw = sys.stdin.read()
    else:
        with open(args.input, encoding="utf-8") as handle:
            raw = handle.read()
    payload = build_payload(json.loads(raw))

    if args.dry_run or not args.webhook_url:
        print(json.dumps(payload, ensure_ascii=False))
        return 0
    status = post(args.webhook_url, payload)
    print(f"posted: HTTP {status}")
    return 0 if 200 <= status < 300 else 1


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Lancer toute la suite → passe**

Run: `cd notom-data-dev/scripts && python3 -m pytest test_slack_note.py -v`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git -C notom-data-dev add scripts/slack_note.py scripts/test_slack_note.py
git -C notom-data-dev commit -m "feat(release): CLI slack_note (--dry-run / post webhook)"
```

---

## Task 3: Terraform — secret `slack-release-webhook`

**Files:**
- Modify: `notom-data-infra/modules/data-stack/env-files.tf` (déclaration variable)
- Modify: `notom-data-infra/modules/data-stack/secrets.tf` (ressources secret)
- Modify: `notom-data-infra/envs/prod/variables.tf`, `envs/prod/main.tf`, `envs/prod/terraform.tfvars.example`

> Pas de test unitaire (config) → validation par `terraform validate`. Branche infra propre depuis `main` (cf. Prérequis).

- [ ] **Step 1: Déclarer la variable module**

Dans `notom-data-infra/modules/data-stack/env-files.tf`, après `variable "toucan_api_key"` :
```hcl
variable "slack_release_webhook_url" {
  description = "Webhook Slack du canal DÉDIÉ aux notes de release (≠ slack_webhook_url des alertes data-platform). Vide = pas de secret créé."
  type        = string
  sensitive   = true
  default     = ""
}
```

- [ ] **Step 2: Créer les ressources secret (conditionnelles)**

Dans `notom-data-infra/modules/data-stack/secrets.tf`, ajouter :
```hcl
resource "scaleway_secret" "slack_release_webhook" {
  count       = var.slack_release_webhook_url != "" ? 1 : 0
  name        = "slack-release-webhook-${var.environment}"
  description = "Webhook Slack du canal dédié aux notes de release notom-data (${var.environment}). Lu par le skill notom-data-dev:release."
  tags        = [var.environment, "slack", "release"]
}

resource "scaleway_secret_version" "slack_release_webhook" {
  count     = var.slack_release_webhook_url != "" ? 1 : 0
  secret_id = scaleway_secret.slack_release_webhook[0].id
  data      = var.slack_release_webhook_url
}
```
> `data` = la valeur brute (URL ASCII) ; le skill la lit via `scw secret version access … -o json | jq -r .data | base64 -d` (un seul `base64 -d`, contrairement aux `.env` qui sont en double base64).

- [ ] **Step 3: Câbler l'env prod**

Dans `notom-data-infra/envs/prod/variables.tf`, après `variable "toucan_api_key"` :
```hcl
variable "slack_release_webhook_url" {
  type      = string
  sensitive = true
  default   = ""
}
```

Dans `notom-data-infra/envs/prod/main.tf`, dans le bloc `module "data_stack"`, après `toucan_api_key` :
```hcl
  slack_release_webhook_url = var.slack_release_webhook_url
```

Dans `notom-data-infra/envs/prod/terraform.tfvars.example`, à la fin :
```hcl
# Webhook Slack du canal DÉDIÉ aux notes de release (≠ alertes data-platform).
slack_release_webhook_url = "https://hooks.slack.com/services/..."
```

- [ ] **Step 4: fmt + validate**

Run:
```bash
cd notom-data-infra && terraform fmt -recursive && (cd envs/prod && terraform validate)
```
Expected: `Success! The configuration is valid.`

- [ ] **Step 5: Commit**

```bash
git -C notom-data-infra add modules/data-stack/env-files.tf modules/data-stack/secrets.tf envs/prod/variables.tf envs/prod/main.tf envs/prod/terraform.tfvars.example
git -C notom-data-infra commit -m "feat(secrets): secret Scaleway slack-release-webhook (canal release dédié)"
```

- [ ] **Step 6 (déploiement — manuel, hors agent) : renseigner + apply**

> Étape humaine : coller la vraie URL dans `envs/prod/terraform.tfvars` (gitignored) :
> `slack_release_webhook_url = "<URL du canal dédié>"`, puis :
> ```bash
> cd notom-data-infra/envs/prod
> set -a; source ~/.scw-prod-credentials; export AWS_ACCESS_KEY_ID="$SCW_ACCESS_KEY"; export AWS_SECRET_ACCESS_KEY="$SCW_SECRET_KEY"; set +a
> terraform apply -refresh=false -target='module.data_stack.scaleway_secret.slack_release_webhook' -target='module.data_stack.scaleway_secret_version.slack_release_webhook'
> ```
> Vérif : `scw secret secret list -o json | jq -r '.[].name' | grep slack-release-webhook-prod`.

---

## Task 4: Skill `release` — mode « tout »

**Files:**
- Modify: `notom-data-dev/skills/release/SKILL.md`

> Fichier d'instructions (pas de test auto). Validation = Task 5.

- [ ] **Step 1: Mettre à jour le principe « une app à la fois »**

Dans `notom-data-dev/skills/release/SKILL.md`, section `## Principes`, remplacer la puce :
```
- **Une release = UNE app, choisie explicitement** + une action délibérée. Pour plusieurs apps,
  relancer la procédure pour chacune (pas de release multi-repo en un geste).
```
par :
```
- Deux modes : **une app** (par défaut) ou **tout** (release des apps ayant du nouveau, cf. section
  dédiée). Dans les deux cas, déclenchement explicite et délibéré.
```

- [ ] **Step 2: Ajouter la section « Mode tout »**

Ajouter dans `notom-data-dev/skills/release/SKILL.md`, après la section « Faire une release » :
````markdown
## Mode « tout » (les 3 apps en un geste + note Slack)

Déclenché quand l'utilisateur dit « release tout / livrer tout / release all / tout mettre en prod ».
Repos : `notom-connect-analytics` (préfixe `analytics`), `notom-data-platform` (`data-platform`),
`notom-cloud-gateway` (`gateway`).

1. **Calculer le périmètre** des 3 repos :
   ```bash
   for r in notom-connect-analytics:analytics notom-data-platform:data-platform notom-cloud-gateway:gateway; do
     repo=${r%%:*}; prefix=${r##*:}
     git -C "$repo" fetch origin --tags --quiet
     LAST=$(git -C "$repo" tag --list "$prefix-*" --sort=-creatordate | head -1)
     echo "## $repo (dernier tag: ${LAST:-aucun})"
     git -C "$repo" log --oneline ${LAST:+$LAST..}origin/main
   done
   ```
   Les repos **sans commit nouveau** sont **sautés** (notés « déjà à jour »).

2. **Récap unique + 1 confirmation** : présenter le tableau (apps à livrer + leurs commits/PR ; apps
   sautées) ; avertir (gateway = blip routage TOUS services ; analytics/data-platform = restart
   ~30-60 s). **Demander UNE confirmation** pour l'ensemble. Si rien nulle part → le dire, stop.

3. **Exécuter séquentiellement** (pour chaque app à livrer) :
   ```bash
   gh workflow run deploy-prod.yml --repo notomio/<repo>
   # récupérer l'id du run lancé puis :
   gh run watch <id> --repo notomio/<repo> --exit-status
   ```
   Si une app **échoue** : **arrêter** les suivantes, rapporter ce qui est passé / pas passé, et
   **NE PAS** poster la note Slack — demander à l'utilisateur (re-tenter / rollback / note partielle).

4. **Récupérer les nouveaux tags** (par app livrée) :
   `git -C <repo> ls-remote --tags origin | grep "<prefix>-" | sort | tail -1`, et la
   `platform_version` depuis `notom-data-infra` (`git -C notom-data-infra show origin/main:prod-versions.yaml`).

5. **Poster la note consolidée** :
   ```bash
   WEBHOOK=$(scw secret version access slack-release-webhook-prod revision=latest_enabled -o json \
     | jq -r .data | base64 -d)
   # construire release.json : {platform_version, date(YYYY-MM-DD), released:[{app,version,changes:[...]}], skipped:[...]}
   python3 notom-data-dev/scripts/slack_note.py --input release.json --webhook-url "$WEBHOOK"
   ```
   `changes` = les commits/PR calculés à l'étape 1. (Tester d'abord avec `--dry-run` pour relire le rendu.)

6. **Vérifier** (comme en mode une app) : tags posés, GitHub Releases, `prod-versions.yaml` à jour, apps prod répondent.
````

- [ ] **Step 3: Commit**

```bash
git -C notom-data-dev add skills/release/SKILL.md
git -C notom-data-dev commit -m "feat(skill): mode « tout » (release multi-app + note Slack consolidée)"
```

---

## Task 5: Validation de bout en bout (manuelle)

**Files:** aucun (vérification).

- [ ] **Step 1: Périmètre à blanc** — lancer la boucle de l'étape 1 du mode « tout » ; vérifier que la liste apps/commits est correcte. Aucun déploiement.

- [ ] **Step 2: Format de la note (dry-run)** — fabriquer un `release.json` représentatif et :
```bash
python3 notom-data-dev/scripts/slack_note.py --input release.json --dry-run
```
Vérifier : header (platform + date), une ligne par app livrée avec `(N PR)`, puces des changements, `manifest:`, et pied `non releasées…` si des apps sont sautées.

- [ ] **Step 3: Post de test** — une fois le secret en place (Task 3 step 6), poster une note de **test** sur le canal dédié :
```bash
WEBHOOK=$(scw secret version access slack-release-webhook-prod revision=latest_enabled -o json | jq -r .data | base64 -d)
python3 notom-data-dev/scripts/slack_note.py --input release.json --webhook-url "$WEBHOOK"
```
Vérifier que le message arrive bien dans le canal et que le rendu mrkdwn est correct.

- [ ] **Step 4: Cas « rien à livrer »** — si les 3 apps sont à jour, le mode « tout » doit l'annoncer et **ne pas** poster sur Slack.

---

## Self-Review (rempli)

- **Spec coverage** : périmètre apps-avec-nouveau → Task 4 step 1-2 ; note consolidée → Task 1/2 + Task 4 step 5 ; confirmation unique → Task 4 step 2 ; webhook secret codifié TF → Task 3 ; format note → Task 1 ; gestion d'erreur (arrêt + pas de Slack) → Task 4 step 3 ; tests (dry-run, rien-à-livrer, format) → Task 5. ✅
- **Placeholders** : `<repo>`, `<prefix>`, `<id>`, `<URL…>` = paramètres de commande (légitimes), pas de TODO/TBD. ✅
- **Cohérence des noms** : `build_payload`, `post`, `main` (Task 1↔2) ; secret `slack-release-webhook-${var.environment}` ↔ lecture `slack-release-webhook-prod` (Task 3↔4) ; clés JSON `platform_version/date/released/skipped/app/version/changes` identiques (Task 1↔4). ✅
