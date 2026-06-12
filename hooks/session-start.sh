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
- Rollback : deploy-prod.yml workflow_dispatch avec input ref=<tag>.'

jq -n --arg ctx "$ctx" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $ctx
  }
}'
exit 0
