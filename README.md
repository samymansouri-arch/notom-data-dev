# notom-data-dev — plugin Claude Code (bonnes pratiques Notom)

Propage le workflow de dev/release et les garde-fous de la Notom Cloud Data Platform à
chaque session Claude **interactive** (laptop + SSH sur les VM). Compose avec superpowers.

## Installer

> ⚠️ Ce repo est **privé** : l'install **clone** le marketplace, ce qui exige des **identifiants GitHub**
> dans la session. C'est une **étape manuelle, par machine** (pas d'auto-provisioning IaC, choix assumé).

### Sur le laptop
```
/plugin marketplace add samymansouri-arch/notom-data-dev
/plugin install notom-data-dev@notom-data-dev
```

### Sur une VM staging (étape manuelle, à refaire à chaque (re)build de VM)
**Prérequis :** être dans ta session **VS Code Remote-SSH avec l'agent SSH forwardé** (`ssh -A` / `ForwardAgent yes`)
— sinon le clone du repo privé échoue (pas de creds sur la VM). Lance, dans cette session, sur la VM :
```
/plugin marketplace add samymansouri-arch/notom-data-dev
/plugin install notom-data-dev@notom-data-dev
```
Équivalent CLI (non-interactif) : `claude plugin marketplace add samymansouri-arch/notom-data-dev && claude plugin install notom-data-dev@notom-data-dev`.

**Vérifier :** `claude plugin list` doit afficher `notom-data-dev@notom-data-dev … ✔ enabled`.

> Le message `⚠ 1 setup issue: plugins · /doctor` au démarrage = le clone du repo privé n'a pas encore
> abouti (creds absents) → ouvre Claude **avec l'agent forwardé** et relance l'install. Une fois cloné, le warning disparaît.

> **VM de prod : inutile.** Le code y est livré par `rsync` (sans `.git`) → ce ne sont pas des dépôts git,
> on n'y commit pas, le plugin n'a rien à y faire.

## Mettre à jour
```
/plugin marketplace update notom-data-dev
```

## Contenu
- **Skill `/notom-data-dev:release`** — procédure de release (PR dev→main, tag CalVer, manifeste) + rollback.
- **Hook SessionStart** — injecte les bonnes pratiques dans les repos `notomio/*` (silencieux ailleurs).
- **Hook PreToolUse** — refuse `commit`/`push` direct sur `main` (repos notomio, sessions interactives).
  Échappatoire : `NOTOM_SKIP_HOOKS=1`.
- **`.pre-commit-config.yaml`** (committé dans chaque repo app) — anti-secrets (gitleaks), yamllint,
  `docker compose config`, `dbt parse`. Couvre TOUS les commits (Claude ou manuel) via `pre-commit install`.

## Limite connue (vérifiée)
Les hooks Claude Code (`PreToolUse`, `SessionStart`) ne se déclenchent **qu'en session interactive**
— pas en `claude -p` / headless. La couverture complète repose donc sur 3 couches :
1. hook Claude (UX, refus expliqué en interactif),
2. `pre-commit` (tous les commits),
3. branch protection serveur sur `main` (filet ultime).

## Docs
- `docs/2026-06-04-dev-release-workflow-design.md` — spec du workflow
- `docs/2026-06-04-notom-dev-plugin-design.md` — spec du plugin
- `docs/2026-06-04-dev-release-workflow.md` / `docs/2026-06-04-notom-dev-plugin.md` — plans
