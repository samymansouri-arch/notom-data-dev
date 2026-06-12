---
name: release
description: "Use when shipping/releasing a Notom app to prod (notom-connect-analytics, notom-data-platform, notom-cloud-gateway): the release is an EXPLICIT action separate from merging to main. Proposes the release scope (unreleased commits since the last tag), then runs the deploy workflow (deploy + CalVer tag + global manifest + GitHub Release); also handles rollback. Invoke when the user says 'release', 'releaser', 'livrer', 'mettre en prod', 'pousser en prod', 'déployer (en prod)', 'ship', or asks to roll back. ALSO invoke this to clarify the next step whenever a PR to main was just opened/merged and someone might think that 'releases' — it does NOT."
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
- **Une release = UNE app, choisie explicitement** + une action délibérée. Pour plusieurs apps,
  relancer la procédure pour chacune (pas de release multi-repo en un geste).
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
