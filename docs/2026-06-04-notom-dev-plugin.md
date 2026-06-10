# Plugin `notom-dev` — Plan d'implémentation (Projet #2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Construire et distribuer un plugin Claude Code `notom-dev` qui propage les bonnes pratiques de dev/release à chaque session Claude **interactive** (laptop + SSH sur les VM), via un skill `/notom-dev:release`, un fragment de contexte chargé au démarrage, des hooks de garde-fou, et un `.pre-commit-config.yaml` par repo.

**Architecture :** Un repo git `notomio/notom-dev` structuré en plugin Claude Code auto-hébergé (manifeste + `marketplace.json` à la racine). Il embarque : (1) un skill `release` (procédure du projet #1, déléguant aux skills superpowers), (2) un hook `SessionStart` injectant le fragment de bonnes pratiques **uniquement dans les repos notomio**, (3) un hook `PreToolUse` (garde branche) qui **refuse** commit/push direct sur `main` en session interactive, (4) des `.pre-commit-config.yaml` par repo (anti-secrets, validation configs, `dbt parse`) qui tournent **quel que soit le contexte** (Claude ou manuel).

**Contrainte clé (vérifiée auprès du guide Claude Code) :** les hooks `PreToolUse`/`SessionStart` ne se déclenchent **que dans les sessions interactives** — pas en `claude -p`/headless. Conséquence assumée : couverture en 3 couches → hook Claude (UX en interactif) + `pre-commit` (tous les commits) + branch protection serveur (projet #1, filet ultime). Les hooks sont scopés aux repos `notomio/*` pour ne pas polluer les autres projets de la machine.

**Tech Stack :** format plugin Claude Code (`.claude-plugin/plugin.json`, `marketplace.json`, `skills/`, `hooks/hooks.json`), bash + jq (hooks), framework `pre-commit` (gitleaks, yamllint, hooks locaux compose/dbt).

**Dépend de :** [Plan workflow dev/release](./2026-06-04-dev-release-workflow.md) (projet #1) — le skill `/release` encode cette procédure. **Faire le projet #1 d'abord.**

**Référence spec :** `docs/specs/2026-06-04-notom-dev-plugin-design.md`

**Contrat de hook (référence, vérifié) :**
- Entrée stdin (PreToolUse) : JSON avec `.tool_name`, `.tool_input.command`, `.cwd`, `.hook_event_name`.
- Refuser : imprimer sur stdout `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"…"}}` puis `exit 0`. (Alternative : `exit 2` + message sur stderr.)
- Autoriser : `exit 0` sans sortie.
- SessionStart : imprimer `{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"…"}}`.
- `hooks/hooks.json` : matcher `"Bash"`, commande via `${CLAUDE_PLUGIN_ROOT}`.
- Skill invocable : `/notom-dev:release` (+ auto-invocable par le modèle via sa `description`).
- Install : `/plugin marketplace add notomio/notom-dev` puis `/plugin install notom-dev@notom-dev`.

---

## Phase 1 — Scaffolding du repo plugin

Tout se fait dans un nouveau dossier `notom-dev/` (futur repo `notomio/notom-dev`). On y déplacera aussi les specs/plans (décision brainstorming : ce repo est leur maison).

### Task 1.1 : Initialiser le repo et la structure plugin

**Files:**
- Create: `notom-dev/.claude-plugin/plugin.json`
- Create: `notom-dev/.claude-plugin/marketplace.json`
- Create: `notom-dev/.gitignore`

- [ ] **Step 1 : Créer le dossier et git init**

```bash
cd /Users/samymansouri/dev/notom-connect/cloud-data-platform
mkdir -p notom-dev/.claude-plugin notom-dev/skills notom-dev/hooks
cd notom-dev && git init -b main
```

- [ ] **Step 2 : Écrire le manifeste plugin**

Create `notom-dev/.claude-plugin/plugin.json` :
```json
{
  "name": "notom-dev",
  "description": "Bonnes pratiques de dev/release de la Notom Cloud Data Platform : workflow feat→dev→release, garde-fous git, checks pre-commit. Compose avec superpowers.",
  "version": "0.1.0",
  "author": { "name": "Notom", "email": "samy.mansouri@notom.io" },
  "keywords": ["workflow", "release", "git", "pre-commit", "notom"]
}
```

- [ ] **Step 3 : Écrire le marketplace (auto-hébergé)**

Create `notom-dev/.claude-plugin/marketplace.json` :
```json
{
  "name": "notom-dev",
  "description": "Marketplace interne Notom (plugin notom-dev)",
  "owner": { "name": "Notom", "email": "samy.mansouri@notom.io" },
  "plugins": [
    {
      "name": "notom-dev",
      "description": "Bonnes pratiques de dev/release Notom",
      "version": "0.1.0",
      "source": "./"
    }
  ]
}
```

- [ ] **Step 4 : .gitignore + commit initial**

```bash
cd notom-dev
printf '.DS_Store\n__pycache__/\n*.pyc\n' > .gitignore
git add .
git commit -m "chore: scaffold notom-dev Claude Code plugin"
```

- [ ] **Step 5 : Valider la syntaxe JSON**

```bash
cd notom-dev
for f in .claude-plugin/plugin.json .claude-plugin/marketplace.json; do
  python3 -c "import json,sys; json.load(open('$f')); print('OK $f')"
done
```
Attendu : `OK …` pour les deux fichiers.

---

## Phase 2 — Skill `/release`

### Task 2.1 : Écrire le skill de release

**Files:**
- Create: `notom-dev/skills/release/SKILL.md`

- [ ] **Step 1 : Écrire le SKILL.md**

Create `notom-dev/skills/release/SKILL.md` :
```markdown
---
name: release
description: "Use when shipping a release to prod for a Notom app repo (gateway, analytics, data-platform). Guides the dev→main release PR, the approval gate, CalVer tagging, and rollback. Invoke when the user says 'release', 'mettre en prod', 'déployer en prod', or asks how to roll back."
---

# Release d'une app Notom en prod

Procédure standard (voir spec `2026-06-04-dev-release-workflow-design.md`).

## Pré-requis
- Le travail est mergé dans `dev` (via PR `feat/* → dev`) et validé sur la VM staging.
- On ne pousse JAMAIS directement sur `main` (le hook + la branch protection le refusent).

## Faire une release
1. Confirmer avec l'utilisateur l'app à releaser et que `dev` est vert sur staging.
2. Ouvrir la PR de release :
   `gh pr create --base main --head dev --title "release: <app> $(date -u +%Y.%m.%d)" --body "<liste des PR embarquées>"`
   La liste des PR embarquées = `git log --oneline main..dev`.
3. Faire relire/valider, puis merger la PR (`gh pr merge --merge`).
4. La CD "Deploy to prod" démarre puis ATTEND une approbation (environnement `production`).
   Demander à l'utilisateur d'approuver dans Actions → Review deployments.
5. Après approbation : la CD déploie, pose le tag `<prefix>-YYYY.MM.DD`, et met à jour
   `notom-data-infra/prod-versions.yaml`. Préfixes : gateway→`gateway`, analytics→`analytics`,
   data-platform→`data-platform`.
6. Vérifier : `git fetch --tags && git tag --list "<prefix>-*"`, et l'app prod répond.

## Rollback
1. Trouver le tag cible : `git tag --list "<prefix>-*"`.
2. `gh workflow run deploy-prod.yml -f ref="<prefix>-YYYY.MM.DD"`.
3. Approuver le déploiement. Le tag est redéployé ; aucun nouveau tag n'est posé.
   ⚠️ Le rollback ne restaure PAS les secrets (toujours la version courante du Secret Manager).

## Skills superpowers à composer (ne pas réécrire)
- Avant de releaser : `superpowers:verification-before-completion` (preuves que dev est vert).
- Pour la revue : `superpowers:requesting-code-review`.
- Pour clôturer une branche de feature : `superpowers:finishing-a-development-branch`.
```

- [ ] **Step 2 : Vérifier le frontmatter**

```bash
cd notom-dev
python3 - <<'PY'
import re
t = open("skills/release/SKILL.md").read()
assert t.startswith("---"), "frontmatter manquant"
fm = t.split("---")[1]
assert "name: release" in fm and "description:" in fm, "name/description requis"
print("SKILL.md frontmatter OK")
PY
git add skills/release/SKILL.md && git commit -m "feat(skill): add /release procedure skill"
```
Attendu : `SKILL.md frontmatter OK`.

---

## Phase 3 — Hooks (garde-fous interactifs)

### Task 3.1 : Hook SessionStart — fragment de bonnes pratiques (scopé notomio)

**Files:**
- Create: `notom-dev/hooks/session-start.sh`
- Create: `notom-dev/hooks/hooks.json`

- [ ] **Step 1 : Écrire le hook SessionStart**

Create `notom-dev/hooks/session-start.sh` :
```bash
#!/usr/bin/env bash
# Injecte les bonnes pratiques Notom UNIQUEMENT si la session est dans un repo notomio.
set -euo pipefail
input="$(cat)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
[ -n "$cwd" ] || exit 0

remote="$(git -C "$cwd" remote get-url origin 2>/dev/null || true)"
case "$remote" in
  *notomio/*) ;;          # repo Notom → on injecte
  *) exit 0 ;;            # autre projet → on ne pollue pas
esac

ctx='Bonnes pratiques Notom (plugin notom-dev) :
- Travaille sur une branche feat/*, JAMAIS directement sur main.
- Commits Conventional Commits (fix:, feat:, chore:, ci: ...).
- Les feat/* se mergent dans dev (PR) ; dev tourne sur la VM staging.
- Lance les checks avant de commit (pre-commit : secrets, configs, dbt parse).
- Staging = clone git : commit/push depuis la VM (pas de drift).
- Pour livrer en prod : skill /notom-dev:release (release PR dev→main + approbation + tag CalVer).
- Rollback : deploy-prod.yml workflow_dispatch avec input ref=<tag>.'

jq -n --arg ctx "$ctx" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $ctx
  }
}'
exit 0
```

- [ ] **Step 2 : Rendre exécutable + enregistrer dans hooks.json**

```bash
cd notom-dev && chmod +x hooks/session-start.sh
```

Create `notom-dev/hooks/hooks.json` :
```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|clear|compact",
        "hooks": [
          { "type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh\"" }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/guard-git.sh\"" }
        ]
      }
    ]
  }
}
```

- [ ] **Step 3 : Tester le hook SessionStart (injecte dans repo notomio, rien ailleurs)**

```bash
cd notom-dev
# Cas 1 : cwd dans un repo notomio simulé
TMP=$(mktemp -d); git -C "$TMP" init -q; git -C "$TMP" remote add origin https://github.com/notomio/x.git
printf '{"cwd":"%s"}' "$TMP" | ./hooks/session-start.sh | jq -e '.hookSpecificOutput.additionalContext | test("JAMAIS directement sur main")' >/dev/null && echo "OK notomio inject"
# Cas 2 : cwd dans un repo non-notomio
TMP2=$(mktemp -d); git -C "$TMP2" init -q; git -C "$TMP2" remote add origin https://github.com/autre/y.git
out=$(printf '{"cwd":"%s"}' "$TMP2" | ./hooks/session-start.sh); [ -z "$out" ] && echo "OK non-notomio silencieux"
```
Attendu : `OK notomio inject` puis `OK non-notomio silencieux`.

### Task 3.2 : Hook PreToolUse — garde branche `main` (TDD)

**Files:**
- Create: `notom-dev/hooks/guard-git.sh`
- Test: `notom-dev/hooks/test-guard.sh`

Refuse, dans un repo notomio uniquement : `git commit` sur `main`, et tout `git push` qui cible `main` (branche courante `main`, ou `origin main`/`HEAD:main`/`:main`). Échappatoire : `NOTOM_SKIP_HOOKS=1`.

- [ ] **Step 1 : Écrire le test qui échoue**

Create `notom-dev/hooks/test-guard.sh` :
```bash
#!/usr/bin/env bash
# Harnais de test du garde git. Crée des repos temporaires sur des branches données.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HERE/guard-git.sh"
fail=0

mk_repo() { # $1=remote-url $2=branch
  d=$(mktemp -d); git -C "$d" init -q
  git -C "$d" remote add origin "$1"
  git -C "$d" commit -q --allow-empty -m init
  git -C "$d" checkout -q -B "$2"
  printf '%s' "$d"
}
run() { # stdin JSON -> stdout decision ; $1 cwd $2 command
  printf '{"cwd":"%s","tool_name":"Bash","tool_input":{"command":%s}}' "$1" "$(jq -Rn --arg c "$2" '$c')" | "$GUARD"
}
assert_deny()  { echo "$1" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null && echo "PASS $2" || { echo "FAIL $2"; fail=1; }; }
assert_allow() { [ -z "$1" ] && echo "PASS $2" || { echo "FAIL $2 (got: $1)"; fail=1; }; }

NOTOMIO=https://github.com/notomio/x.git
OTHER=https://github.com/autre/y.git

r=$(mk_repo "$NOTOMIO" main);   assert_deny  "$(run "$r" 'git commit -m "x"')"        "commit sur main (notomio) refusé"
r=$(mk_repo "$NOTOMIO" feat/x); assert_allow "$(run "$r" 'git commit -m "x"')"        "commit sur feat/x autorisé"
r=$(mk_repo "$NOTOMIO" feat/x); assert_deny  "$(run "$r" 'git push origin main')"      "push origin main refusé"
r=$(mk_repo "$NOTOMIO" feat/x); assert_deny  "$(run "$r" 'git push origin HEAD:main')" "push HEAD:main refusé"
r=$(mk_repo "$NOTOMIO" feat/x); assert_allow "$(run "$r" 'git push origin feat/x')"    "push feat/x autorisé"
r=$(mk_repo "$OTHER"   main);   assert_allow "$(run "$r" 'git commit -m "x"')"        "commit sur main hors-notomio autorisé"
r=$(mk_repo "$NOTOMIO" main);   NOTOM_SKIP_HOOKS=1; export NOTOM_SKIP_HOOKS
  assert_allow "$(run "$r" 'git commit -m "x"')" "échappatoire NOTOM_SKIP_HOOKS"; unset NOTOM_SKIP_HOOKS
r=$(mk_repo "$NOTOMIO" main);   assert_allow "$(run "$r" 'ls -la')"                    "commande non-git autorisée"

exit $fail
```

```bash
cd notom-dev && chmod +x hooks/test-guard.sh && ./hooks/test-guard.sh
```
Attendu : FAIL partout (`guard-git.sh` n'existe pas encore / non exécutable).

- [ ] **Step 2 : Écrire `guard-git.sh`**

Create `notom-dev/hooks/guard-git.sh` :
```bash
#!/usr/bin/env bash
# Refuse commit/push sur main dans les repos notomio. Échappatoire : NOTOM_SKIP_HOOKS=1.
set -uo pipefail

# Échappatoire explicite
[ "${NOTOM_SKIP_HOOKS:-}" = "1" ] && exit 0

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
[ -n "$cmd" ] || exit 0
[ -n "$cwd" ] || exit 0

# Ne s'applique qu'aux repos notomio
remote="$(git -C "$cwd" remote get-url origin 2>/dev/null || true)"
case "$remote" in *notomio/*) ;; *) exit 0 ;; esac

branch="$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"

deny() {
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# Détecte une opération git commit / git push
is_git() { printf '%s' "$cmd" | grep -Eq '(^|[;&| ])git([ ]|$)'; }
is_commit() { printf '%s' "$cmd" | grep -Eq 'git[ ].*commit'; }
is_push() { printf '%s' "$cmd" | grep -Eq 'git[ ].*push'; }
push_targets_main() { printf '%s' "$cmd" | grep -Eq '(origin[ ]+main|HEAD:main|:main([ ]|$))'; }

is_git || exit 0

if is_commit && [ "$branch" = "main" ]; then
  deny "Commit direct sur main interdit (workflow Notom). Crée une branche feat/* puis ouvre une PR dev→main. Skill : /notom-dev:release. Échappatoire : NOTOM_SKIP_HOOKS=1."
fi

if is_push && { [ "$branch" = "main" ] || push_targets_main; }; then
  deny "Push direct sur main interdit (workflow Notom). Passe par une PR dev→main. Skill : /notom-dev:release. Échappatoire : NOTOM_SKIP_HOOKS=1."
fi

exit 0
```

- [ ] **Step 3 : Rendre exécutable + lancer les tests pour les voir passer**

```bash
cd notom-dev && chmod +x hooks/guard-git.sh && ./hooks/test-guard.sh
```
Attendu : 9 lignes `PASS …`, exit 0.

- [ ] **Step 4 : Commit**

```bash
cd notom-dev
git add hooks/
git commit -m "feat(hooks): session-start context + git branch guard (scoped to notomio) with tests"
```

---

## Phase 4 — `.pre-commit-config.yaml` par repo (couche robuste)

Cette couche tourne pour TOUS les commits (Claude interactif, headless, ou manuel). Chaque hook absent d'outil **s'auto-skippe** (pas de blocage si l'outil n'est pas installé localement).

### Task 4.1 : analytics — secrets + yaml + compose

**Files:**
- Create: `<ANALYTICS>/.pre-commit-config.yaml`

- [ ] **Step 1 : Brancher**

```bash
cd <ANALYTICS> && git checkout dev && git pull && git checkout -b feat/pre-commit
```

- [ ] **Step 2 : Écrire la config**

Create `<ANALYTICS>/.pre-commit-config.yaml` :
```yaml
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.21.2
    hooks:
      - id: gitleaks
  - repo: https://github.com/adrienverge/yamllint
    rev: v1.35.1
    hooks:
      - id: yamllint
        args: ["-d", "relaxed"]
  - repo: local
    hooks:
      - id: compose-config
        name: docker compose config (prod)
        entry: bash -c 'command -v docker >/dev/null || { echo "docker absent, skip"; exit 0; }; docker compose -f docker-compose-prod.yml config -q'
        language: system
        files: 'docker-compose.*\.ya?ml$'
        pass_filenames: false
```

- [ ] **Step 3 : Installer pre-commit et lancer sur tout le repo**

```bash
cd <ANALYTICS>
python3 -m pip install --quiet pre-commit
pre-commit install            # installe le hook git .git/hooks/pre-commit
pre-commit run --all-files || true   # 1er passage : corriger ce qui remonte (yaml, secrets)
```
Attendu : gitleaks `Passed`, yamllint `Passed` (corriger les éventuels findings), compose-config `Passed` ou `skip` si docker absent.

- [ ] **Step 4 : Commit + PR vers dev**

```bash
cd <ANALYTICS>
git add .pre-commit-config.yaml
git commit -m "chore(quality): add pre-commit (gitleaks, yamllint, compose config)"
git push -u origin feat/pre-commit
gh pr create --repo notomio/notom-connect-analytics --base dev --head feat/pre-commit \
  --title "chore(quality): pre-commit hooks" --body "Anti-secrets + yamllint + validation docker compose."
```
Attendu : PR créée → merger dans dev.

### Task 4.2 : data-platform — + `dbt parse`

**Files:**
- Create: `<DP>/.pre-commit-config.yaml`

- [ ] **Step 1 : Brancher + écrire la config**

```bash
cd <DP> && git checkout dev && git pull && git checkout -b feat/pre-commit
```

Create `<DP>/.pre-commit-config.yaml` :
```yaml
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.21.2
    hooks:
      - id: gitleaks
  - repo: https://github.com/adrienverge/yamllint
    rev: v1.35.1
    hooks:
      - id: yamllint
        args: ["-d", "relaxed"]
  - repo: local
    hooks:
      - id: compose-config
        name: docker compose config
        entry: bash -c 'command -v docker >/dev/null || { echo "docker absent, skip"; exit 0; }; docker compose -f docker-compose.yaml config -q'
        language: system
        files: 'docker-compose.*\.ya?ml$'
        pass_filenames: false
      - id: dbt-parse
        name: dbt parse (compile les modèles)
        entry: bash -c 'command -v dbt >/dev/null || { echo "dbt absent, skip"; exit 0; }; cd dbt/notom_dbt && dbt parse'
        language: system
        files: '^dbt/.*\.(sql|yml|yaml)$'
        pass_filenames: false
```

- [ ] **Step 2 : Installer + lancer**

```bash
cd <DP>
python3 -m pip install --quiet pre-commit
pre-commit install
pre-commit run --all-files || true
```
Attendu : hooks `Passed`/`skip` ; corriger les findings yaml/secrets.

- [ ] **Step 3 : Commit + PR vers dev**

```bash
cd <DP>
git add .pre-commit-config.yaml
git commit -m "chore(quality): add pre-commit (gitleaks, yamllint, compose, dbt parse)"
git push -u origin feat/pre-commit
gh pr create --repo notomio/notom-data-platform --base dev --head feat/pre-commit \
  --title "chore(quality): pre-commit hooks" --body "Anti-secrets + yamllint + compose + dbt parse."
```
Attendu : PR créée → merger dans dev.

### Task 4.3 : gateway — secrets + yaml + compose + placeholders template

**Files:**
- Create: `<GW>/.pre-commit-config.yaml`

- [ ] **Step 1 : Brancher + écrire la config**

```bash
cd <GW> && git checkout dev && git pull && git checkout -b feat/pre-commit
```

Create `<GW>/.pre-commit-config.yaml` :
```yaml
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.21.2
    hooks:
      - id: gitleaks
  - repo: https://github.com/adrienverge/yamllint
    rev: v1.35.1
    hooks:
      - id: yamllint
        args: ["-d", "relaxed"]
  - repo: local
    hooks:
      - id: compose-config
        name: docker compose config
        entry: bash -c 'command -v docker >/dev/null || { echo "docker absent, skip"; exit 0; }; docker compose -f docker-compose.yml config -q'
        language: system
        files: 'docker-compose.*\.ya?ml$'
        pass_filenames: false
      - id: no-rendered-services
        name: ne pas committer services.yml rendu (généré depuis le template)
        entry: bash -c 'if git diff --cached --name-only | grep -qx "traefik/dynamic/services.yml"; then echo "services.yml est généré — ne pas le committer (committe le .template)"; exit 1; fi'
        language: system
        pass_filenames: false
```

- [ ] **Step 2 : Installer + lancer**

```bash
cd <GW>
python3 -m pip install --quiet pre-commit
pre-commit install
pre-commit run --all-files || true
```
Attendu : hooks `Passed`/`skip`.

- [ ] **Step 3 : Commit + PR vers dev**

```bash
cd <GW>
git add .pre-commit-config.yaml
git commit -m "chore(quality): add pre-commit (gitleaks, yamllint, compose, no rendered services)"
git push -u origin feat/pre-commit
gh pr create --repo notomio/notom-cloud-gateway --base dev --head feat/pre-commit \
  --title "chore(quality): pre-commit hooks" --body "Anti-secrets + yamllint + compose + garde services.yml généré."
```
Attendu : PR créée → merger dans dev.

---

## Phase 5 — Distribution & installation

### Task 5.1 : Publier le repo plugin + installer sur le laptop

- [ ] **Step 1 : Créer le repo distant et pousser**

```bash
cd /Users/samymansouri/dev/notom-connect/cloud-data-platform/notom-dev
gh repo create notomio/notom-dev --private --source=. --remote=origin --push
```
Attendu : repo `notomio/notom-dev` créé, branche `main` poussée.

- [ ] **Step 2 : Ajouter le marketplace + installer (dans Claude Code)**

Dans une session Claude Code interactive :
```
/plugin marketplace add notomio/notom-dev
/plugin install notom-dev@notom-dev
```
Attendu : plugin installé ; cache sous `~/.claude/plugins/cache/notom-dev/notom-dev/0.1.0/`.

- [ ] **Step 3 : Vérifier que les garde-fous s'activent (session interactive, repo notomio)**

```bash
# Dans un clone notomio, sur main, tenter un commit via Claude → doit être REFUSÉ avec le message.
# Vérif manuelle du script hors-Claude :
cd <ANALYTICS> && git checkout main
printf '{"cwd":"%s","tool_name":"Bash","tool_input":{"command":"git commit -m test"}}' "$PWD" \
  | ~/.claude/plugins/cache/notom-dev/notom-dev/0.1.0/hooks/guard-git.sh \
  | jq -r '.hookSpecificOutput.permissionDecision'
```
Attendu : `deny`. Et `/notom-dev:release` apparaît dans la liste des skills.

### Task 5.2 : Installer sur chaque VM (SSH)

- [ ] **Step 1 : Sur chaque VM (data-platform, analytics, + gateway si Claude y est utilisé)**

```bash
# En SSH sur la VM, dans une session claude INTERACTIVE :
/plugin marketplace add notomio/notom-dev
/plugin install notom-dev@notom-dev
```

- [ ] **Step 2 : Vérifier l'injection SessionStart**

Ouvrir `claude` interactif dans `/opt/<app>` (un repo notomio) → le contexte de bonnes pratiques doit être présent. Hors d'un repo notomio → rien.

> ⚠️ Rappel : en `claude -p`/headless sur la VM, les hooks NE tournent PAS. La protection repose alors sur `pre-commit` (Phase 4) + la branch protection serveur (projet #1).

### Task 5.3 : Doc d'installation + déplacement des specs/plans

**Files:**
- Create: `notom-dev/README.md`
- Move: `docs/specs/*.md`, `docs/plans/*.md` → `notom-dev/docs/`

- [ ] **Step 1 : README**

Create `notom-dev/README.md` :
```markdown
# notom-dev — plugin Claude Code (bonnes pratiques Notom)

## Installer (laptop + chaque VM, session Claude interactive)
    /plugin marketplace add notomio/notom-dev
    /plugin install notom-dev@notom-dev

## Mettre à jour
    /plugin marketplace update notom-dev   (puis réinstaller si besoin)

## Contenu
- Skill `/notom-dev:release` — procédure de release/rollback.
- Hook SessionStart — injecte les bonnes pratiques dans les repos notomio.
- Hook PreToolUse — refuse commit/push direct sur main (repos notomio, sessions interactives).
  Échappatoire : `NOTOM_SKIP_HOOKS=1`.
- `.pre-commit-config.yaml` (dans chaque repo app) — anti-secrets, yamllint, compose, dbt parse.

## Limite connue
Les hooks Claude Code ne s'activent qu'en session INTERACTIVE (pas `claude -p`/headless).
Couverture complète assurée par : hook Claude (interactif) + pre-commit (tous commits) + branch protection serveur.

## Docs
- `docs/2026-06-04-dev-release-workflow-design.md` (spec workflow)
- `docs/2026-06-04-notom-dev-plugin-design.md` (spec plugin)
- `docs/2026-06-04-dev-release-workflow.md` / `docs/2026-06-04-notom-dev-plugin.md` (plans)
```

- [ ] **Step 2 : Déplacer specs + plans dans le repo plugin et committer**

```bash
cd /Users/samymansouri/dev/notom-connect/cloud-data-platform
mkdir -p notom-dev/docs
mv docs/specs/*.md notom-dev/docs/ 2>/dev/null || true
mv docs/plans/*.md notom-dev/docs/ 2>/dev/null || true
mv docs/RELEASE.md notom-dev/docs/ 2>/dev/null || true
cd notom-dev
git add README.md docs/
git commit -m "docs: add README + import specs/plans (home of dev-practice docs)"
git push
```
Attendu : specs/plans versionnés dans `notomio/notom-dev`.

---

## Auto-revue (faite)

**Couverture spec ↔ plan :**
- Plugin distribué par git, installé partout (spec §3, §5) → Phase 1 (scaffold) + Phase 5 (publish/install). ✓
- Composition avec superpowers, pas de réécriture (spec §3, §4.1) → SKILL.md référence verification/code-review/finishing-a-branch. ✓
- Niveau 2 garde-fous locaux (spec §3, §4.3) → hook PreToolUse `guard-git.sh` + pre-commit Phase 4. ✓
- 3 checks rapides : secrets, configs, dbt parse (spec §4.4) → Phase 4 (gitleaks, compose config/yamllint, dbt parse). ✓
- Fragment bonnes pratiques chargé (spec §4.2) → hook SessionStart `session-start.sh`. ✓
- Skill `/release` (spec §4.1) → Phase 2. ✓
- Échappatoire documentée (spec §4.3, critère §9.6) → `NOTOM_SKIP_HOOKS=1` (hook) + `--no-verify` (pre-commit), documentés dans README + messages de refus. ✓
- pre-commit couvre aussi les commits manuels (spec §4.4) → installé via `pre-commit install`. ✓
- Specs/plans → maison `notom-dev` (décision brainstorming) → Task 5.3. ✓

**Placeholders :** aucun `TODO`/`TBD` ; `<ANALYTICS>`/`<DP>`/`<GW>` sont des chemins de clones explicités en en-tête du plan #1 ; `rev:` pinné pour gitleaks/yamllint.

**Cohérence des noms :** `guard-git.sh`/`session-start.sh` identiques entre `hooks.json`, les tâches et les tests ; `NOTOM_SKIP_HOOKS` identique partout ; `permissionDecision`/`hookSpecificOutput`/`additionalContext` conformes au contrat vérifié ; matcher `"Bash"` et `${CLAUDE_PLUGIN_ROOT}` conformes.

**Contrainte headless intégrée :** notée en en-tête, en Task 5.2, et dans le README — la couverture ne repose pas uniquement sur les hooks.

**Hors-scope confirmé (spec §7) :** pas de CI bloquante, pas de tests dbt lourds en pre-commit, pas d'env local, pas de réécriture superpowers. ✓
```
