#!/usr/bin/env bash
# Installe le plugin notom-data-dev sur une VM Notom, SANS dépendre d'un agent SSH
# forwardé. Repose sur le fait que le repo est PUBLIC → clone HTTPS anonyme.
#
# Pourquoi ce script : `claude plugin marketplace add` clone TOUJOURS en SSH
# (git@github.com, StrictHostKeyChecking=yes) → exige une clé GitHub dans la session.
# Sur une VM provisionnée sans clé (auth = agent forwardé seulement), ça échoue.
# Ce script clone en HTTPS et place le plugin + son registre à la main.
#
# Usage (en tant que l'utilisateur qui lance Claude, ex. notom) :
#   bash install-on-vm.sh
# Idempotent. À relancer après un (re)build de VM (l'install n'est pas dans l'IaC, choix assumé).

set -euo pipefail

REPO="samymansouri-arch/notom-data-dev"
NAME="notom-data-dev"
VERSION="0.1.0"
PDIR="$HOME/.claude/plugins"
MKT="$PDIR/marketplaces/$NAME"
CACHE="$PDIR/cache/$NAME/$NAME/$VERSION"

mkdir -p "$PDIR/marketplaces" "$PDIR/cache"

echo "→ Clone HTTPS (anonyme, repo public) du marketplace…"
rm -rf "$MKT"
git clone --depth 1 "https://github.com/$REPO.git" "$MKT"
SHA="$(git -C "$MKT" rev-parse HEAD)"

echo "→ Copie dans le cache d'install…"
rm -rf "$PDIR/cache/$NAME"
mkdir -p "$CACHE"
cp -a "$MKT/." "$CACHE/"
rm -rf "$CACHE/.git"

echo "→ Enregistrement dans le registre Claude Code (merge, préserve l'existant)…"
python3 - "$SHA" "$PDIR" "$NAME" "$VERSION" "$REPO" <<'PY'
import json, os, sys, datetime
sha, p, name, version, repo = sys.argv[1:6]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
km = os.path.join(p, "known_marketplaces.json")
d = json.load(open(km)) if os.path.exists(km) else {}
d[name] = {"source": {"source": "github", "repo": repo},
           "installLocation": os.path.join(p, "marketplaces", name), "lastUpdated": now}
json.dump(d, open(km, "w"), indent=2)
ip = os.path.join(p, "installed_plugins.json")
e = json.load(open(ip)) if os.path.exists(ip) else {"version": 2, "plugins": {}}
e.setdefault("plugins", {})[f"{name}@{name}"] = [{
    "scope": "user",
    "installPath": os.path.join(p, "cache", name, name, version),
    "version": version, "installedAt": now, "lastUpdated": now, "gitCommitSha": sha}]
json.dump(e, open(ip, "w"), indent=2)
print("registres mis à jour")
PY

echo "→ Vérification :"
claude plugin list 2>/dev/null | grep -A3 "$NAME" || true
echo "✓ Terminé. Le plugin est actif à la prochaine session Claude interactive sur cette VM."
