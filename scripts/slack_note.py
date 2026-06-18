#!/usr/bin/env python3
"""Construit (et poste) la note de release consolidée pour Slack.

Entrée : JSON décrivant la release (platform_version, date, released[], skipped[]).
"""

import argparse
import json
import sys
import urllib.request


def build_payload(release: dict) -> dict:
    """release: dict. released[i] = {app, version, changes:[str]}.
    Retourne {"text": <mrkdwn Slack>}."""
    lines = [
        f"🚀 Release prod notom-data — platform "
        f"{release['platform_version']} — {release['date']}"
    ]
    for app in release["released"]:
        n = len(app["changes"])
        lines.append(f"• {app['app']} → {app['version']}  ({n} PR)")
        for change in app["changes"]:
            lines.append(f"    – {change}")
    lines.append("manifest: prod-versions.yaml")
    skipped = release.get("skipped") or []
    if skipped:
        lines.append(f"_(non releasées car déjà à jour : {', '.join(skipped)})_")
    return {"text": "\n".join(lines)}


def post(webhook_url: str, payload: dict) -> int:
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        webhook_url, data=data, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=15) as resp:  # noqa: S310
        return resp.status


def main(argv=None):
    parser = argparse.ArgumentParser(description="Poste la note de release Slack.")
    parser.add_argument("--input", default="-", help="Fichier JSON ('-' = stdin).")
    parser.add_argument("--webhook-url", default="", help="URL du webhook Slack Incoming.")
    parser.add_argument("--dry-run", action="store_true", help="Affiche le payload sans poster.")
    args = parser.parse_args(argv)

    if args.input == "-":
        raw = sys.stdin.read()
    else:
        with open(args.input, encoding="utf-8") as handle:
            raw = handle.read()
    payload = build_payload(json.loads(raw))

    if args.dry_run or not args.webhook_url:
        print(json.dumps(payload, ensure_ascii=False))
        return 0
    status = post(args.webhook_url, payload)
    print(f"posted: HTTP {status}")
    return 0 if 200 <= status < 300 else 1


if __name__ == "__main__":
    sys.exit(main())
