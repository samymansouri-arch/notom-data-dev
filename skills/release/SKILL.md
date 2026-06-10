---
name: release
description: "Use when shipping a release to prod for a Notom app repo (notom-connect-analytics, notom-data-platform, notom-cloud-gateway). Guides the explicit release (deploy + CalVer tag + global manifest + GitHub Release) and rollback. Invoke when the user says 'release', 'mettre en prod', 'déployer en prod', or asks how to roll back a deploy."
---

# Release d'une app Notom en prod

Procédure du workflow de release versionné (modèle **release explicite découplée du merge**,
en place depuis 2026-06-10). Voir la spec `docs/2026-06-04-dev-release-workflow-design.md`.

## Modèle (important)
- `feat/*` → PR → `dev` (intégration ; `dev` validé sur la VM staging).
- `dev → main` (PR) = **intégrer le code dans `main`. Cela NE déploie PAS** (le trigger `push:main`
  a été retiré). On ne pousse jamais directement sur `main` (branch protection + hook notom-dev).
- **Une release = une action EXPLICITE** : `gh workflow run deploy-prod.yml` (sans `ref`). C'est le
  geste délibéré qui : déploie `main`, pose le tag `<prefix>-AAAA.MM.JJ[.N]`, met à jour
  `notom-data-infra/prod-versions.yaml` (+ `platform_version` global), et crée une **GitHub Release**
  (notes auto). Tu choisis QUAND release, indépendamment de QUAND tu merges.

Préfixes de tag : `notom-connect-analytics`→`analytics`, `notom-data-platform`→`data-platform`,
`notom-cloud-gateway`→`gateway`.

## Faire une release
1. S'assurer que le code voulu est sur `main` (mergé depuis `dev`) et validé sur staging.
2. Prévenir si sensible : la **gateway** redéploie Traefik (bref blip de routage pour TOUS les
   services) ; analytics/data-platform redémarrent leurs conteneurs ~30-60s.
3. Lancer la release explicite :
   `gh workflow run deploy-prod.yml --repo notomio/<repo>`  (aucun input → release de `main`).
4. Surveiller : `gh run watch <id> --repo notomio/<repo> --exit-status`.
5. Vérifier : tag posé (`git ls-remote --tags origin | grep <prefix>`) ; GitHub Release créée
   (`gh release list --repo notomio/<repo>`) ; `prod-versions.yaml` à jour sur `notom-data-infra@main` ;
   l'app prod répond.

## Rollback (revenir à une version)
1. Trouver le tag cible : `git ls-remote --tags origin | grep <prefix>`.
2. `gh workflow run deploy-prod.yml --repo notomio/<repo> -f ref="<prefix>-AAAA.MM.JJ"`.
3. Surveiller. Le tag est redéployé ; le job `finalize` est **sauté** (aucun nouveau tag, ni Release,
   ni maj manifeste). ⚠️ Le rollback porte sur le code/config versionné, PAS sur les secrets
   (toujours la version courante du Scaleway Secret Manager).

## Composer avec superpowers (ne pas réécrire)
- Avant de releaser : `superpowers:verification-before-completion` (preuves que dev est vert).
- Revue : `superpowers:requesting-code-review`.
- Clôturer une branche de feature : `superpowers:finishing-a-development-branch`.
