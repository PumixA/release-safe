# Validation de la chaîne de livraison

Essais réalisés le 6 novembre 2026 sur l'environnement local (Docker 29, Compose v5), avec les
scripts du dépôt. Chaque ligne peut être rejouée avec les commandes indiquées.

## Livraisons réelles

| Version | Résultat | Détecté par | Impact client |
|---|---|---|---|
| 1.0.0 | déployée (staging, production) | — | — |
| 1.1.0 | **refusée** | tests de contrat (CI) ; image forcée : smoke test avant bascule (`120 km = 10.4`) | aucun |
| 1.2.0, 1er essai | **rejetée en staging** | smoke test : devis 120 km > 5 s (12 s annoncées) | aucun |
| 1.2.0 après adaptation de l'infra | déployée (staging, production) | — | 0 erreur |

## Absence de coupure

`scripts/traffic.sh` envoyé pendant les opérations (devis courts en continu + un devis
long de 12 s toutes les 5 s) :

| Opération | Requêtes | Erreurs |
|---|---|---|
| staging : bascule 1.0.0 → 1.2.0 | 362 (dont 15 devis longs) | **0** |
| production : bascule 1.0.0 → 1.2.0, rollback vers 1.0.0, retour vers 1.2.0 | 449 (dont 20 devis longs) | **0** |

## Arrêt gracieux (1.2.0)

Requête de 12 s en cours, arrêt du conteneur 2 s après son début :

| Délai accordé par Docker | Résultat de la requête |
|---|---|
| 35 s (`stop_grace_period` retenu) | HTTP 200 en 12,0 s |
| 5 s | coupée (HTTP 000 après 7 s) |

D'où `stop_grace_period: 35s` : le processus s'accorde 30 s et Docker ne doit pas le tuer avant.

## Scénarios de panne (images de test, staging)

| Scénario | Comportement attendu | Résultat |
|---|---|---|
| Barème faux (1.1.0) | rejet avant bascule | ✅ `RELEASE REJETÉE`, trafic resté sur la version active |
| Version trop lente (1.2.0 avant adaptation) | rejet avant bascule | ✅ rejet, aucune bascule |
| Plante au démarrage | rejet immédiat | ✅ rejet en 1 s (au lieu d'attendre 90 s, corrigé par le commit « deploy: détection des crashs au démarrage et après bascule ») |
| Plante 14 s après démarrage (après la bascule) | rollback automatique | ✅ crash détecté pendant l'observation, retour automatique sur 1.2.0 |
| Rollback alors que la couleur de secours n'est plus disponible | redéploiement depuis l'image | ✅ `rollback.sh staging 1.2.0` redéploie 1.2.0 avec tous les contrôles |
| Rollback instantané | bascule en ~1 s, sans erreur | ✅ |

## Qualité

- `npm test` : 26 tests (4 fournis 1.0.0, 4 fournis 1.2.0, 18 tests de contrat de l'équipe).
- `shellcheck -x scripts/*.sh` : aucun avertissement.
- `docker compose config` valide pour staging et production.
- Image : utilisateur `node`, code non modifiable par le processus (vérifié : `touch` refusé).
