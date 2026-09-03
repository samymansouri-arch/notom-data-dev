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

# ⚠ Le dépôt visé n'est PAS forcément $cwd : `git -C <chemin>` opère ailleurs.
#   Juger sur $cwd donnait DEUX verdicts faux, dans les deux sens :
#     - faux positif  : `git -C ~/brain commit` lancé depuis un repo notomio était REFUSÉ,
#       alors que ~/brain n'a rien à voir avec le workflow Notom (constaté le 2026-09-03) ;
#     - faux négatif  : un commit sur un repo notomio lancé depuis un dossier tiers PASSAIT.
#   On résout donc le dépôt réellement ciblé avant de décider.
repo_dir="$cwd"
target="$(printf '%s' "$cmd" | grep -oE 'git[[:space:]]+-C[[:space:]]+[^[:space:]]+' | head -1 | sed -E 's/.*-C[[:space:]]+//')"
target="${target%\"}"; target="${target#\"}"; target="${target%\'}"; target="${target#\'}"
if [ -n "$target" ]; then
  case "$target" in
    "~")   target="$HOME" ;;
    "~/"*) target="$HOME/${target#\~/}" ;;
    /*)    ;;
    *)     target="$cwd/$target" ;;
  esac
  repo_dir="$target"
fi

# Ne s'applique qu'aux repos notomio
remote="$(git -C "$repo_dir" remote get-url origin 2>/dev/null || true)"
case "$remote" in *notomio/*) ;; *) exit 0 ;; esac

branch="$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"

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
  deny "Commit direct sur main interdit (workflow Notom). Crée une branche feat/* puis ouvre une PR dev->main. Skill : /notom-data-dev:release. Échappatoire : NOTOM_SKIP_HOOKS=1."
fi

if is_push && { [ "$branch" = "main" ] || push_targets_main; }; then
  deny "Push direct sur main interdit (workflow Notom). Passe par une PR dev->main. Skill : /notom-data-dev:release. Échappatoire : NOTOM_SKIP_HOOKS=1."
fi

exit 0
