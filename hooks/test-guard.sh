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
run() { # $1 cwd $2 command -> stdout decision
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

# ── Ménage post-merge : supprimer des branches mergées n'est pas un push sur main ──────
# Régression du 2026-09-08 : refusé depuis le checkout principal (HEAD=main), alors que la
# commande ne touche pas main. Les cinq cas ci-dessous verrouillent le comportement voulu.
r=$(mk_repo "$NOTOMIO" main);   assert_allow "$(run "$r" 'git push origin --delete feat/x fix/y release/z')" "suppression de branches mergées depuis main autorisée"
r=$(mk_repo "$NOTOMIO" main);   assert_allow "$(run "$r" 'git push origin -d feat/x')"              "suppression forme courte -d autorisée"
r=$(mk_repo "$NOTOMIO" main);   assert_allow "$(run "$r" 'git push origin :feat/x')"                "suppression par refspec vide autorisée"
r=$(mk_repo "$NOTOMIO" main);   assert_allow "$(run "$r" 'git push origin --delete feat/main-fix')" "branche dont le NOM contient main : suppression autorisée"
r=$(mk_repo "$NOTOMIO" feat/x); assert_deny  "$(run "$r" 'git push origin --delete main')"          "supprimer main REFUSÉ"
r=$(mk_repo "$NOTOMIO" feat/x); assert_deny  "$(run "$r" 'git push origin --delete refs/heads/main')" "supprimer refs/heads/main REFUSÉ"
r=$(mk_repo "$NOTOMIO" main);   assert_deny  "$(run "$r" 'git push origin main')"                   "push sur main toujours refusé (non-régression)"
export NOTOM_SKIP_HOOKS=1
r=$(mk_repo "$NOTOMIO" main);   assert_allow "$(run "$r" 'git commit -m "x"')" "échappatoire NOTOM_SKIP_HOOKS"
unset NOTOM_SKIP_HOOKS
r=$(mk_repo "$NOTOMIO" main);   assert_allow "$(run "$r" 'ls -la')"                    "commande non-git autorisée"

exit $fail
