#!/usr/bin/env bash
# Test du hook nudge-release.sh : doit injecter un rappel UNIQUEMENT pour
# `gh pr create … --base main`, silencieux sinon.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NUDGE="$HERE/nudge-release.sh"
fail=0

run() { # $1 = commande -> stdout du hook
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(jq -Rn --arg c "$1" '$c')" | "$NUDGE"
}
assert_nudge()  { echo "$1" | jq -e '.hookSpecificOutput.additionalContext | test("n.?est PAS une release|pas une release|RAPPEL Notom")' >/dev/null && echo "PASS $2" || { echo "FAIL $2 (attendu: nudge)"; fail=1; }; }
assert_silent() { [ -z "$1" ] && echo "PASS $2" || { echo "FAIL $2 (attendu: silencieux, got: $1)"; fail=1; }; }

assert_nudge  "$(run 'gh pr create --base main --head dev --title x')"        "create --base main → nudge"
assert_nudge  "$(run 'gh pr create --base=main --head dev')"                  "create --base=main → nudge"
assert_silent "$(run 'gh pr create --base dev --head feat/x')"                "create --base dev → silencieux"
assert_silent "$(run 'gh pr merge 12 --repo notomio/x --merge')"              "pr merge (num) → silencieux"
assert_silent "$(run 'gh pr create --base main-backup --head x')"            "base main-backup → silencieux (pas main)"
assert_silent "$(run 'git push origin feat/x')"                               "git push feat → silencieux"
assert_silent "$(run 'ls -la')"                                               "commande quelconque → silencieux"

exit $fail
