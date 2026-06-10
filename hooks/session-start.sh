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
- Pour livrer en prod : skill /notom-dev:release (release PR dev->main ; le merge declenche le deploy + tag CalVer + manifeste).
- Rollback : deploy-prod.yml workflow_dispatch avec input ref=<tag>.'

jq -n --arg ctx "$ctx" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $ctx
  }
}'
exit 0
