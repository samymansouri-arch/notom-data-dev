---
name: release
description: "Use when shipping/releasing a Notom app to prod (notom-connect-analytics, notom-data-platform, notom-cloud-gateway): the release is an EXPLICIT action separate from merging to main. Two modes: ONE app, or ALL apps that have unreleased commits in one go (mode « tout », with one consolidated confirmation + a consolidated release note posted to a dedicated Slack channel). Proposes the release scope (unreleased commits since the last tag), then runs the deploy workflow (deploy + CalVer tag + global manifest + GitHub Release); also handles rollback. Invoke when the user says 'release', 'releaser', 'livrer', 'mettre en prod', 'pousser en prod', 'déployer (en prod)', 'ship', 'release tout', 'release all', 'livrer tout', 'tout mettre en prod', or asks to roll back. ALSO invoke this to clarify the next step whenever a PR to main was just opened/merged and someone might think that 'releases' — it does NOT."
---

# Release d'une app Notom en prod

> ⛔️ **À LIRE EN PREMIER — l'erreur classique à NE PAS commettre :**
> Ouvrir ou merger une PR vers `main` **n'est PAS une release** : c'est juste de l'**intégration de
> code**, et **ça ne déploie RIEN** (le trigger `push:main` a été retiré). La release est une
> **action explicite et distincte** : `gh workflow run deploy-prod.yml`. Si tu t'arrêtes après la
> PR/merge vers `main`, **tu n'as pas releasé** — il reste l'étape 4 ci-dessous. Ne réponds jamais
> « c'est releasé / mis en prod » tant que le workflow de déploiement n'a pas tourné avec succès.

Modèle : **release explicite, une app à la fois** (en place depuis 2026-06-10).
Spec : `docs/2026-06-04-dev-release-workflow-design.md`.

## Principes
- `feat/*` → PR → `dev` (intégration, validée sur la VM staging) → PR → `main`.
- **Merger sur `main` NE déploie PAS** (intégration seulement ; trigger `push:main` retiré).
- Deux modes : **une app** (par défaut) ou **tout** (release des apps ayant du nouveau, cf. section
  dédiée). Dans les deux cas, déclenchement explicite et délibéré.
- Préfixes de tag : `notom-connect-analytics`→`analytics`, `notom-data-platform`→`data-platform`,
  `notom-cloud-gateway`→`gateway`.

## Faire une release (procédure que Claude DOIT suivre)

1. **Choisir l'app.** Si l'utilisateur ne l'a pas dite, demander laquelle des 3.

2. **Proposer le périmètre** (ne jamais releaser à l'aveugle). Pour le repo choisi :
   ```bash
   git -C <repo> fetch origin --tags --quiet
   LAST=$(git -C <repo> tag --list "<prefix>-*" --sort=-creatordate | head -1)
   git -C <repo> log --oneline ${LAST:+$LAST..}origin/main
   ```
   Présenter à l'utilisateur : le dernier tag releasé, et **la liste des commits/PR de `main` non
   encore releasés** (= ce qui partira). Relier explicitement aux changements faits dans la session
   en cours. Si rien de nouveau depuis le dernier tag → le dire et ne pas releaser.
   **Demander confirmation du périmètre.**

3. **Prévenir si sensible** : gateway = redéploiement Traefik → bref blip de routage pour TOUS les
   services ; analytics/data-platform = redémarrage conteneurs ~30-60s.

4. **Lancer la release explicite** (après confirmation) :
   ```bash
   gh workflow run deploy-prod.yml --repo notomio/<repo>
   ```
   (aucun input → release de la version courante de `main`).

5. **Surveiller** : `gh run watch <id> --repo notomio/<repo> --exit-status`.

6. **Vérifier** : tag posé (`git ls-remote --tags origin | grep <prefix>`) ; GitHub Release créée
   (`gh release list --repo notomio/<repo>`) ; `notom-data-infra@main:prod-versions.yaml` à jour
   (version de l'app + `platform_version`) ; l'app prod répond.

## Mode « tout » (les 3 apps en un geste + note Slack)

Déclenché quand l'utilisateur dit « release tout / livrer tout / release all / tout mettre en prod ».
Repos : `notom-connect-analytics` (préfixe `analytics`), `notom-data-platform` (`data-platform`),
`notom-cloud-gateway` (`gateway`).

1. **Calculer le périmètre** des 3 repos :
   ```bash
   for r in notom-connect-analytics:analytics notom-data-platform:data-platform notom-cloud-gateway:gateway; do
     repo=${r%%:*}; prefix=${r##*:}
     git -C "$repo" fetch origin --tags --quiet
     LAST=$(git -C "$repo" tag --list "$prefix-*" --sort=-creatordate | head -1)
     echo "## $repo (dernier tag: ${LAST:-aucun})"
     git -C "$repo" log --oneline ${LAST:+$LAST..}origin/main
   done
   ```
   Les repos **sans commit nouveau** sont **sautés** (notés « déjà à jour »).

2. **Récap unique + 1 confirmation** : présenter le tableau (apps à livrer + leurs commits/PR ; apps
   sautées) ; avertir (gateway = blip routage TOUS services ; analytics/data-platform = restart
   ~30-60 s). **Demander UNE confirmation** pour l'ensemble. Si rien nulle part → le dire, stop.

3. **Exécuter séquentiellement** (pour chaque app à livrer) :
   ```bash
   gh workflow run deploy-prod.yml --repo notomio/<repo>
   # récupérer l'id du run lancé puis :
   gh run watch <id> --repo notomio/<repo> --exit-status
   ```
   Si une app **échoue** : **arrêter** les suivantes, rapporter ce qui est passé / pas passé, et
   **NE PAS** poster la note Slack — demander à l'utilisateur (re-tenter / rollback / note partielle).

4. **Récupérer les nouveaux tags** (par app livrée) :
   `git -C <repo> ls-remote --tags origin | grep "<prefix>-" | sort | tail -1`, et la
   `platform_version` depuis `notom-data-infra` (`git -C notom-data-infra show origin/main:prod-versions.yaml`).

5. **Poster la note consolidée** :
   ```bash
   WEBHOOK=$(scw secret version access-by-path secret-name=slack-release-webhook-prod secret-path=/ revision=latest_enabled -o json \
     | jq -r .data | base64 -d)
   # construire release.json : {platform_version, date(YYYY-MM-DD), released:[{app,version,changes:[...]}], skipped:[...]}
   python3 notom-data-dev/scripts/slack_note.py --input release.json --webhook-url "$WEBHOOK"
   ```
   `changes` = les commits/PR calculés à l'étape 1. (Tester d'abord avec `--dry-run` pour relire le rendu.)

6. **Vérifier** (comme en mode une app) : tags posés, GitHub Releases, `prod-versions.yaml` à jour, apps prod répondent.

## Rollback (revenir à une version)
1. Lister les tags : `git ls-remote --tags origin | grep <prefix>`.
2. `gh workflow run deploy-prod.yml --repo notomio/<repo> -f ref="<prefix>-AAAA.MM.JJ"`.
3. Surveiller. Le tag est redéployé ; le job `finalize` est **sauté** (aucun nouveau tag/Release/manifeste).
   ⚠️ Le rollback porte sur le code/config versionné, PAS sur les secrets (toujours la version courante
   du Scaleway Secret Manager).

## Composer avec superpowers (ne pas réécrire)
- Avant de releaser : `superpowers:verification-before-completion`.
- Revue : `superpowers:requesting-code-review`.
- Clôturer une branche : `superpowers:finishing-a-development-branch`.
