# Runbook — livraison d'une version potentiellement défectueuse

Procédure suivie pour toute nouvelle version, et en particulier pour la version fournie
vendredi. Objectif : **détecter l'échec, préserver le service, revenir à une version stable**,
sans jamais modifier la production à la main ni le code métier.

## 0. Avant de commencer

```bash
scripts/status.sh production        # version active, version de secours, santé
scripts/smoke-test.sh http://localhost:8080
```

Noter la version active : c'est la version stable de référence.

## 1. Intégrer la version sur une branche

```bash
git switch -c release/x.y.z
# reprendre src/, package.json et les nouveaux tests de l'archive (sans toucher à nos tests)
# lire les notes de version : délais, comportement au démarrage / à l'arrêt, variables
npm test
```

| Résultat | Interprétation | Suite |
|---|---|---|
| Tests de contrat en échec | défaut fonctionnel (ex. 1.1.0 : barème faux > 100 km) | **stop**, compte rendu, rien n'est livré |
| Tests fournis en échec | version incohérente avec ses propres tests | **stop** |
| Tout passe | — | étape 2 |

Push de la branche → pipeline : tests, shellcheck, détection de secrets.

## 2. Staging (automatique après fusion dans main)

Le job `deploy_staging` exécute `scripts/deploy.sh staging <sha>`.

| Sortie du script | Signification | Impact |
|---|---|---|
| `... n'est jamais devenue prête` | ne démarre pas, plante, `/readyz` jamais à 200 | aucun : trafic resté sur l'ancienne version |
| `RELEASE REJETÉE : smoke test en échec` | mauvais montant, mauvaise version, 5xx, trop lent | aucun |
| `ROLLBACK AUTOMATIQUE` | échec observé après bascule | quelques secondes au plus, retour auto |
| `=== x.y.z en service ...` | version validée en staging | — |

Diagnostic : logs de la couleur rejetée (conservés, conteneur arrêté mais pas supprimé) :

```bash
docker compose -p cargoflow-staging -f deploy/compose.yaml logs --tail 100 green
```

Si l'échec vient d'un **paramètre d'exploitation** documenté dans les notes de version (délai
de démarrage, timeout, délai d'arrêt), on adapte l'infrastructure dans un commit dédié, jamais
le code métier (ex. 1.2.0 : commit `deploy: adaptation aux contraintes d'exploitation`).

## 3. Production (manuel, depuis un tag)

```bash
git tag -a vX.Y.Z -m "CargoFlow X.Y.Z" && git push origin vX.Y.Z
```

Dans GitHub : *Actions* → exécution du tag → **Review deployments** → approuver `production`.
Pour la démonstration, lancer en parallèle le générateur de trafic :

```bash
scripts/traffic.sh http://localhost:8080 120
```

## 4. Problème découvert après la livraison

```bash
scripts/rollback.sh production      # ou Actions > CI/CD > Run workflow > rollback / production
```

- La couleur de secours (version précédente, toujours démarrée) est revérifiée puis remise
  en service en ~1 s, sans coupure.
- Si elle n'est plus disponible : `scripts/rollback.sh production <version_stable>` redéploie
  la version stable depuis son image, avec tous les contrôles.

## 5. Après l'incident

```bash
scripts/status.sh production                      # version stable active
cat "$CARGOFLOW_STATE_ROOT/production/history.log"   # ou .state/production/history.log en local
```

Rédiger le compte rendu dans `docs/incidents/` : symptôme, détection, impact, décision,
enseignements (voir [l'incident 1.1.0](incidents/2026-11-05-release-1.1.0.md)).

## Démonstration complète (locale)

```bash
# Version stable en production
scripts/build.sh v1.2.0 && scripts/deploy.sh production 1.2.0

# Version défectueuse : image construite depuis sa branche
scripts/build.sh release/x.y.z            # refusé si les tests échouent
# pour démontrer la barrière de déploiement, forcer l'image :
D=$(mktemp -d); git archive release/x.y.z | tar -x -C "$D"
docker build --build-arg APP_VERSION=x.y.z -t cargoflow-api:x.y.z "$D"; rm -rf "$D"

scripts/traffic.sh http://localhost:8080 90 &
scripts/deploy.sh production x.y.z        # rejet ou rollback automatique
wait                                      # 0 requête en erreur
scripts/status.sh production
```
