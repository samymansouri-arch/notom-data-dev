#!/usr/bin/env python3
"""Construit (et poste) la note de release consolidée pour Slack.

Entrée : JSON décrivant la release (platform_version, date, released[], skipped[]).
"""


def build_payload(release):
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
