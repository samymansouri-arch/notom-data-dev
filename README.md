# notom-data-dev — plugin Claude Code (bonnes pratiques Notom)

Propage le workflow de dev/release et les garde-fous de la Notom Cloud Data Platform à
chaque session Claude **interactive** (laptop + SSH sur les VM). Compose avec superpowers.

## Installer

> Le repo est **public** (aucun secret dedans). Installer = **étape manuelle, par machine** (pas
> d'auto-provisioning IaC, choix assumé → à refaire après un (re)build de VM).
> ⚠️ **Important :** `claude plugin marketplace add` clone **toujours en SSH** (`git@github.com`,
> `StrictHostKeyChecking=yes`). Il faut donc (a) `github.com` dans le `known_hosts` de l'utilisateur,
> et (b) une **clé SSH GitHub** dans la session. D'où les deux méthodes ci-dessous.

### Sur le laptop
```
/plugin marketplace add samymansouri-arch/notom-data-dev
/plugin install notom-data-dev@notom-data-dev
```

### Sur une VM staging — méthode A : dans ta session (agent forwardé)
Dans ta session **VS Code Remote-SSH avec l'agent SSH forwardé** (`ForwardAgent yes`, comme pour tes `git push`),
en t'assurant que `github.com` est connu (`ssh-keyscan github.com >> ~/.ssh/known_hosts`) :
```
/plugin marketplace add samymansouri-arch/notom-data-dev
/plugin install notom-data-dev@notom-data-dev
```

### Sur une VM staging — méthode B : sans agent (reproductible, recommandée pour un rebuild)
Le repo étant public, on clone en **HTTPS anonyme** et on place le plugin sans aucune clé. Sur la VM,
en tant que l'utilisateur qui lance Claude (`notom`) :
```
bash scripts/install-on-vm.sh      # depuis un clone du repo, ou : curl -fsSL <raw>/scripts/install-on-vm.sh | bash
```

**Vérifier (les deux méthodes) :** `claude plugin list` → `notom-data-dev@notom-data-dev … ✔ enabled`.

> `⚠ 1 setup issue: plugins · /doctor` au démarrage = le clone du marketplace a échoué — le plus souvent
> `github.com` absent du `known_hosts` (mur SSH avant l'auth) ou pas de clé en session. Méthode B l'évite.

> **VM de prod : inutile.** Le code y est livré par `rsync` (sans `.git`) → pas des dépôts git, on n'y
> commit pas, le plugin n'a rien à y faire.

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
