#!/usr/bin/env bash
# Injecte les bonnes pratiques Notom si la session démarre dans un repo notomio OU dans un
# dossier de travail qui héberge des repos notomio (jusqu'à 2 niveaux). Silencieux ailleurs.
set -euo pipefail
input="$(cat)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
[ -n "$cwd" ] || exit 0

# Un repo est "Notom" si son remote origin pointe sur notomio/*.
is_notom_remote() {
  case "$(git -C "$1" remote get-url origin 2>/dev/null || true)" in
    *notomio/*) return 0 ;; *) return 1 ;;
  esac
}

# Détecte le contexte : soit cwd EST un repo notomio, soit cwd est un dossier de
# travail hébergeant des repos notomio jusqu'à 2 niveaux en dessous
# (ex. notom-connect/cloud-data-platform/<repo>). Collecte les repos détectés.
repos=""
if is_notom_remote "$cwd"; then
  repos="$(basename "$cwd")"                       # démarré DANS un repo notomio
else
  for d in "$cwd"/*/; do                           # dossier de travail : parent ou grand-parent
    d="${d%/}"; case "$(basename "$d")" in .*) continue ;; esac
    [ -d "$d" ] || continue
    if is_notom_remote "$d"; then
      repos="$repos $(basename "$d")"              # repo = enfant direct (cwd = cloud-data-platform)
    else
      for e in "$d"/*/; do                         # sinon enfant = sous-projet -> scan ses enfants
        e="${e%/}"; case "$(basename "$e")" in .*) continue ;; esac
        [ -d "$e" ] || continue
        if is_notom_remote "$e"; then repos="$repos $(basename "$e")"; fi   # cwd = notom-connect
      done
    fi
  done
  repos="$(printf '%s' "$repos" | sed 's/^ *//')"
  [ -n "$repos" ] || exit 0                        # aucun repo Notom sous cwd -> on ne pollue pas
fi

ctx='Bonnes pratiques Notom (plugin notom-data-dev) :

⚠️ RÈGLE CONTRE-INTUITIVE À NE PAS OUBLIER — merger une PR sur `main` n’est QUE de l’intégration
et NE DÉPLOIE RIEN. Une PR/merge vers `main` n’est PAS une release. Pour releaser en prod, il FAUT
lancer une action SÉPARÉE : le skill /notom-data-dev:release (qui exécute `gh workflow run
deploy-prod.yml --repo notomio/<repo>`). Tant que ce workflow n’a pas tourné, RIEN n’est en prod.
Ne dis jamais « j’ai releasé » après une simple PR/merge vers main.

- Travaille sur une branche feat/*, JAMAIS directement sur main.
- Commits Conventional Commits (fix:, feat:, chore:, ci: ...).
- Flux : feat/* → PR → dev (intégration, tourne sur la VM staging) → PR → main (intégration, NE DÉPLOIE PAS).
- Lance les checks avant de commit (pre-commit : secrets, configs, dbt parse).
- Staging = clone git : commit/push depuis la VM (pas de drift).
- RELEASE (prod) = étape explicite et distincte : /notom-data-dev:release.
- Rollback : deploy-prod.yml workflow_dispatch avec input ref=<tag>.

Travail concurrent (plusieurs agents en parallèle sur les mêmes repos) :
- Si tu démarres dans un DOSSIER DE TRAVAIL (parent) et non un repo : choisis ton repo, entre dedans (`cd <repo>`), puis applique le workflow. Toute commande git se fait DANS un repo (ou son worktree), jamais dans le parent.
- 1 agent = 1 worktree = 1 branche feat/* FRAÎCHE d’origin/dev. Annonce ta zone (repo + modèles/DAGs/modules) ; ne touche pas le repo/fichier d’un autre agent.
- Fichiers chauds (README.md, CLAUDE.md, dags/dbt_transform.py) = un seul owner à la fois, ou doc reportée à une passe finale unique (jamais édités en parallèle).
- Pas de doublon : 1 tâche = 1 branche = 1 PR (vérifie `git ls-remote --heads origin` avant de brancher, ne recrée pas le même sujet sous un autre préfixe).
- Paralléliser le travail, SÉRIALISER l’intégration : `git fetch && git merge origin/dev` avant ta PR ; un merge vers `dev` à la fois ; un déploiement à la fois par env.
- Cleanup obligatoire après merge : `git branch -d` + `git worktree remove` + `git push origin --delete`.
- Détail isolation/parallélisme/clôture : skills superpowers `using-git-worktrees`, `dispatching-parallel-agents`, `finishing-a-development-branch`.'

jq -n --arg ctx "$ctx" --arg repos "$repos" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: (($repos | if . == "" then "" else "Repos Notom détectés dans ce dossier de travail : \(.).\n\n" end) + $ctx)
  }
}'
exit 0
