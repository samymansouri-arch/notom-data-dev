#!/usr/bin/env bash
# PostToolUse (Bash) — nudge NON bloquant : quand l'agent ouvre une PR vers `main`,
# lui rappeler que c'est de l'INTÉGRATION, pas une release.
# Cible l'erreur classique « PR vers main = je livre » (faux dans le modèle Notom).
set -uo pipefail

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
[ -n "$cmd" ] || exit 0

# Déclencheur : `gh pr create … --base main` (ou --base=main).
if printf '%s' "$cmd" | grep -Eq 'gh[[:space:]]+pr[[:space:]]+create' \
   && printf '%s' "$cmd" | grep -Eq -- '--base[[:space:]=]main([^[:alnum:]_./-]|$)'; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: "RAPPEL Notom (plugin notom-data-dev) : une PR vers `main` = INTÉGRATION du code. Ça NE DÉPLOIE RIEN et ce n’est PAS une release. Pour réellement releaser cette app en prod, l’étape suivante est OBLIGATOIRE : invoque le skill /notom-data-dev:release (qui lance `gh workflow run deploy-prod.yml --repo notomio/<repo>`). Ne présente pas, et ne considère pas, cette PR/merge vers main comme « la release » — tant que le workflow de déploiement n’a pas tourné, rien n’est en prod."
    }
  }'
  exit 0
fi
exit 0
