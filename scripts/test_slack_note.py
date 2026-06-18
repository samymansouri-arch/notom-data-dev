from slack_note import build_payload

BASE = {
    "platform_version": "2026.06.3",
    "date": "2026-06-18",
    "released": [
        {
            "app": "connect-analytics",
            "version": "analytics-2026.06.18",
            "changes": ["NUMI — Exploration Télémétrie (#15)", "dev-init staging (#14)"],
        },
        {
            "app": "data-platform",
            "version": "data-platform-2026.06.18",
            "changes": ["alertes Slack échec asset-triggered (#36)"],
        },
    ],
    "skipped": ["cloud-gateway"],
}


def test_header_has_platform_and_date():
    text = build_payload(BASE)["text"]
    assert text.splitlines()[0] == (
        "🚀 Release prod notom-data — platform 2026.06.3 — 2026-06-18"
    )


def test_app_line_with_pr_count():
    text = build_payload(BASE)["text"]
    assert "• connect-analytics → analytics-2026.06.18  (2 PR)" in text
    assert "• data-platform → data-platform-2026.06.18  (1 PR)" in text


def test_changes_are_bulleted():
    text = build_payload(BASE)["text"]
    assert "    – NUMI — Exploration Télémétrie (#15)" in text
    assert "    – dev-init staging (#14)" in text


def test_manifest_line_present():
    assert "manifest: prod-versions.yaml" in build_payload(BASE)["text"]


def test_skipped_footer_present():
    text = build_payload(BASE)["text"]
    assert "_(non releasées car déjà à jour : cloud-gateway)_" in text


def test_no_skipped_no_footer():
    text = build_payload(dict(BASE, skipped=[]))["text"]
    assert "non releasées" not in text
