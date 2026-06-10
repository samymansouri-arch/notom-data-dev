---
name: release
description: "Use when shipping a release to prod for a Notom app repo (notom-connect-analytics, notom-data-platform, notom-cloud-gateway). Guides the dev→main release PR, CalVer tagging, the global manifest, and rollback. Invoke when the user says 'release', 'mettre en prod', 'déployer en prod', or asks how to roll back a deploy."
---

# Release d'une app Notom en prod

Procédure du workflow de release versionné (déployé 2026-06-10). Voir la spec
`docs/2026-06-04-dev-release-workflow-design.md`.

## Modèle
- `feat/*` → PR → `dev` (intégration). On ne pousse JAMAIS directement sur `main`
  (la branch protection le refuse, et le hook `notom-dev` le bloque en session interactive).
- Une **release** = une PR `dev → main`. Le **merge de cette PR EST le garde-fou** : c'est
  l'acte délibéré qui déclenche le déploiement prod (pas d'approbation GitHub native — plan org).
- Au merge, la CD prod : déploie le commit, pose le tag `<prefix>-AAAA.MM.JJ[.N]`, et met à jour
  `notom-data-infra/prod-versions.yaml` (version par app + `platform_version` global `AAAA.MM.N`).

Préfixes de tag : `notom-connect-analytics`→`analytics`, `notom-data-platform`→`data-platform`,
`notom-cloud-gateway`→`gateway`.

## Faire une release
1. Confirmer avec l'utilisateur l'app à releaser et que `dev` est validé sur staging.
2. Lister les PR embarquées : `git log --oneline origin/main..origin/dev`.
3. Ouvrir la PR de release :
   `gh pr create --repo notomio/<repo> --base main --head dev --title "release: <app> $(date -u +%Y.%m.%d)" --body "<PR embarquées>"`
4. **Avant de merger**, prévenir si c'est sensible : la gateway redéploie Traefik (bref blip de
   routage pour TOUS les services) ; analytics/data-platform redémarrent leurs conteneurs ~30-60s.
5. Merger la PR (`gh pr merge --repo notomio/<repo> --merge`). La CD `Deploy to prod` part sur push `main`.
6. Surveiller : `gh run watch <id> --repo notomio/<repo> --exit-status`.
7. Vérifier : tag posé (`git ls-remote --tags origin | grep <prefix>`) ; `prod-versions.yaml` à jour
   sur `notom-data-infra@main` ; l'app prod répond.

## Rollback (revenir à une version)
1. Trouver le tag cible : `git ls-remote --tags origin | grep <prefix>`.
2. `gh workflow run deploy-prod.yml --repo notomio/<repo> -f ref="<prefix>-AAAA.MM.JJ"`.
3. Surveiller. Le tag est redéployé ; le job `finalize` est **sauté** (aucun nouveau tag, manifeste inchangé).
   ⚠️ Le rollback porte sur le code/config versionné, PAS sur les secrets (toujours la version
   courante du Scaleway Secret Manager).

## Composer avec superpowers (ne pas réécrire)
- Avant de releaser : `superpowers:verification-before-completion` (preuves que dev est vert).
- Revue : `superpowers:requesting-code-review`.
- Clôturer une branche de feature : `superpowers:finishing-a-development-branch`.
