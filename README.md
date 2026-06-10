# notom-data-dev — plugin Claude Code (bonnes pratiques Notom)

Propage le workflow de dev/release et les garde-fous de la Notom Cloud Data Platform à
chaque session Claude **interactive** (laptop + SSH sur les VM). Compose avec superpowers.

## Installer (laptop + chaque VM, session Claude interactive)
```
/plugin marketplace add samymansouri-arch/notom-data-dev
/plugin install notom-data-dev@notom-data-dev
```

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
