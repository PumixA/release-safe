# CargoFlow API — Release Safe

API de devis de livraison de CargoFlow et sa chaîne de livraison : tests, image Docker versionnée,
déploiement **blue/green** derrière **Nginx** en staging et en production, vérification avant
bascule et **rollback** automatisé.

Projet DevOps réalisé par **Melvin Delorme** et **Dayana Keo**.

---

## Sommaire

1. [Architecture](#architecture)
2. [Contenu du dépôt](#contenu-du-dépôt)
3. [Lancer l'API en local](#lancer-lapi-en-local)
4. [Pipeline CI/CD](#pipeline-cicd)
5. [Livrer une version](#livrer-une-version)
6. [Rollback](#rollback)
7. [Exploitation](#exploitation)
8. [Contraintes du projet](#contraintes-du-projet)
9. [Choix techniques](#choix-techniques)

---

## Architecture

```
                         ┌──────────────────────── hôte de déploiement ────────────────────────┐
                         │                                                                     │
 clients ── :8080 ──────►│  Nginx (proxy)  ── route "active" ──►  green : cargoflow-api:1.2.0  │
                         │       │                                                             │
 équipe ── 127.0.0.1:18080 ──►  └─ route "preview" ─────────►  blue  : cargoflow-api:1.0.0  │
 (préversion, locale)    │                                                                     │
                         └─────────────────────────────────────────────────────────────────────┘
```

- Chaque environnement (`staging`, `production`) est un projet Docker Compose distinct
  (`deploy/compose.yaml`) avec trois services : `proxy`, `blue`, `green`.
- **Un seul point d'entrée public** par environnement : `http://localhost:8080` en production,
  `http://localhost:8081` en staging.
- Une **préversion**, accessible uniquement depuis l'hôte (`127.0.0.1:18080` / `18081`), sert à
  tester la nouvelle couleur avant de lui envoyer le trafic.
- La couleur servie est décrite dans un petit fichier généré par les scripts
  (`set $active_color blue;`). Une bascule = réécriture du fichier, `nginx -t` puis
  `nginx -s reload`. Le reload est **gracieux** : les requêtes en cours se terminent sur
  l'ancienne couleur, les nouvelles partent sur la nouvelle. Aucune coupure.
- Après une bascule, l'ancienne couleur **reste démarrée** : c'est la version de secours,
  vers laquelle on peut revenir en une seconde.

| Environnement | Point d'entrée public | Préversion (hôte uniquement) | Déploiement |
|---|---|---|---|
| staging | `http://localhost:8081` | `http://127.0.0.1:18081` | automatique (main et tags) |
| production | `http://localhost:8080` | `http://127.0.0.1:18080` | manuel, depuis un tag `vX.Y.Z` |

## Contenu du dépôt

```
src/, test/                 API (code métier fourni) et tests
  test/api.test.js          tests fournis avec l'API
  test/contract.test.js     tests de contrat de l'équipe (barème, erreurs HTTP)
Dockerfile                  image de production (non-root, healthcheck /readyz, version intégrée)
compose.yaml                lancement local de l'API seule (port 3000)
.gitlab-ci.yml              pipeline CI/CD
deploy/
  compose.yaml              environnement blue/green (proxy + blue + green)
  nginx/                    configuration du reverse proxy
  env/staging.env           paramètres (non secrets) de staging
  env/production.env        paramètres (non secrets) de production
scripts/
  smoke-test.sh             vérification fonctionnelle d'une instance
  deploy.sh                 déploiement blue/green avec vérification et rollback automatique
  rollback.sh               retour arrière
  status.sh                 état d'un environnement
  build.sh                  build local reproductible depuis une référence Git
  traffic.sh                trafic client pendant un déploiement (preuve d'absence de coupure)
docs/
  CHOIX_TECHNIQUES.md       justification des choix
  RUNBOOK_INCIDENT.md       procédure face à une version défectueuse
  VALIDATION.md             essais réalisés et résultats
  incidents/                comptes rendus d'incidents
  notes-de-version/         notes de version fournies (1.1.0, 1.2.0)
```

## Lancer l'API en local

Avec Node.js 22 :

```bash
npm test        # tests fournis + tests de contrat
npm start       # API sur http://localhost:3000
```

Avec Docker (API seule, port 3000) :

```bash
docker compose up --build -d
curl -i http://localhost:3000/readyz
curl -i "http://localhost:3000/api/quote?distanceKm=20&weightKg=3"
docker compose down
```

Barème de référence : 5 € fixes + 0,40 €/km + 0,20 €/kg. Pour 3 kg : 13,60 € sur 20 km,
45,60 € sur 100 km, 53,60 € sur 120 km.

### Particularités de la 1.2.0

D'après ses [notes de version](docs/notes-de-version/1.2.0.md) :

| Comportement | Réglage de l'infrastructure |
|---|---|
| ~20 s d'initialisation, `/readyz` à 503 pendant ce temps | healthcheck sur `/readyz`, `start_period: 40s` ; la bascule attend `/readyz = 200` |
| devis > 100 km : ~12 s | smoke test : 20 s max pour un devis long ; Nginx `proxy_read_timeout 30s` |
| arrêt gracieux jusqu'à 30 s | `stop_grace_period: 35s` (10 s par défaut chez Docker) |

## Pipeline CI/CD

Fichier : `.gitlab-ci.yml`.

| Étape | Jobs | Déclenchement |
|---|---|---|
| `test` | `unit_tests` (rapport JUnit), `shellcheck`, `compose_config`, `secret_detection`, `version_check` (tags) | chaque push |
| `build` | `build_image` : image taguée `<sha>` (+ `<version>` sur un tag), poussée dans le registry GitLab | `main` et tags |
| `verify` | `image_smoke_test` : l'image publiée est démarrée et passe `smoke-test.sh` | `main` et tags |
| `staging` | `deploy_staging` (auto), `rollback_staging` (manuel) | `main` et tags |
| `production` | `deploy_production` (**manuel**), `rollback_production` (manuel) | tags `vX.Y.Z` |

Le code est testé une fois, l'image est construite une fois, et **cette même image** passe en
staging puis en production : on livre exactement ce qui a été vérifié.

### Mise en place du runner de déploiement

Les jobs `staging` et `production` s'exécutent sur la machine de déploiement, via un runner
GitLab en mode `shell` portant le tag `cargoflow-deploy` :

```bash
# Sur la machine de déploiement (Docker, Docker Compose, bash, curl et flock installés)
sudo gitlab-runner register --executor shell --tag-list cargoflow-deploy
sudo usermod -aG docker gitlab-runner
sudo install -d -o gitlab-runner /var/lib/cargoflow      # état des déploiements
```

Aucune variable secrète n'est à créer : l'accès au registry utilise les variables prédéfinies
de GitLab (`CI_REGISTRY_USER`, `CI_REGISTRY_PASSWORD`).

## Livrer une version

### Processus normal (par la CI)

1. Intégrer la nouvelle version sur une branche (`release/x.y.z`) et ouvrir une merge request.
   Les tests, shellcheck et la détection de secrets tournent.
2. Fusionner dans `main` : l'image `<sha>` est construite, vérifiée puis déployée
   **automatiquement en staging**.
3. Taguer la version (`git tag v1.2.0 && git push --tags`) : la version doit correspondre à
   `package.json`. L'image `1.2.0` est publiée, déployée en staging, puis le job
   **`deploy_production` est déclenché manuellement** depuis GitLab.

### Ce que fait `scripts/deploy.sh <env> <tag>`

```
 1. récupère l'image (jamais de build sur le serveur)
 2. démarre la version sur la couleur INACTIVE         ── le service continue sur l'autre couleur
 3. attend /readyz = 200 (healthcheck Docker)          ── échec : release rejetée, trafic inchangé
 4. pointe la préversion sur cette couleur et lance le smoke test
      santé, disponibilité, version exposée, barème 20/100/120 km, 400, 404, temps de réponse
                                                       ── échec : release rejetée, trafic inchangé
 5. bascule Nginx (reload gracieux)
 6. smoke test sur l'URL publique + observation du trafic
                                                       ── échec : retour AUTOMATIQUE à l'ancienne couleur
 7. l'ancienne couleur reste démarrée en secours
```

Chaque opération est tracée dans `.state/<env>/history.log` (date, action, version, couleur,
résultat, auteur, commit). Un verrou empêche deux déploiements simultanés sur un même
environnement.

### Déployer à la main (démonstration locale)

Les scripts sont ceux qu'exécute la CI. Hors CI, on construit l'image depuis Git :

```bash
scripts/build.sh v1.0.0                 # tests + image cargoflow-api:1.0.0 depuis le tag
scripts/deploy.sh production 1.0.0      # premier déploiement -> blue
curl -i http://localhost:8080/api/version

scripts/build.sh v1.2.0
scripts/deploy.sh production 1.2.0      # -> green, blue reste en secours
scripts/status.sh production
```

## Rollback

| Situation | Action | Durée |
|---|---|---|
| Échec avant bascule (pas prête, smoke test KO) | Automatique : la release est rejetée, le trafic n'a jamais quitté l'ancienne version | — |
| Échec juste après bascule | Automatique : `deploy.sh` rebascule sur l'ancienne couleur | ~1 s |
| Problème détecté plus tard | `scripts/rollback.sh <env>` ou job `rollback_production` | ~1 s |
| Revenir à une version précise | `scripts/rollback.sh <env> <version>` : redéploiement complet depuis l'image | ~30 s |

```bash
scripts/rollback.sh production          # retour instantané sur la couleur de secours
scripts/rollback.sh production 1.0.0    # redéploie 1.0.0 depuis son image (mêmes contrôles)
```

Le rollback instantané revérifie la couleur de secours (smoke test sur la préversion) avant de
lui rendre le trafic. Si elle n'est plus disponible, le script redéploie la version précédente
depuis son image : un rollback est un déploiement comme un autre, donc reproductible.

## Historique des livraisons

| Version | Statut | Détail |
|---|---|---|
| 1.0.0 | livrée | version de référence (`v1.0.0`) |
| 1.1.0 | **refusée** | barème faux au-delà de 100 km — [compte rendu](docs/incidents/2026-11-05-release-1.1.0.md) |
| 1.2.0 | livrée | après adaptation de l'infrastructure (`v1.2.0`) |

Essais de déploiement, de rollback et de pannes : [docs/VALIDATION.md](docs/VALIDATION.md).
Procédure pour la version défectueuse de vendredi : [docs/RUNBOOK_INCIDENT.md](docs/RUNBOOK_INCIDENT.md).

## Exploitation

```bash
scripts/status.sh production            # couleurs, versions, santé, dernières opérations
scripts/smoke-test.sh http://localhost:8080
docker compose -p cargoflow-production -f deploy/compose.yaml logs -f proxy   # couleur servie par requête
curl -si http://localhost:8080/api/version | grep -i x-cargoflow-color
scripts/traffic.sh http://localhost:8080 60                                  # trafic de test, compte les erreurs
```

## Contraintes du projet

- **Aucun secret dans Git** : aucun identifiant dans le dépôt, accès registry par les variables
  prédéfinies GitLab, `.env*` ignorés, job `secret_detection` dans le pipeline.
- **Aucune modification manuelle de la production** : la production n'est modifiée que par
  `deploy.sh` / `rollback.sh`, lancés par les jobs manuels du pipeline (tag Git → image → job).
  L'état est tenu par les scripts, pas édité à la main.
- **Reproductibilité** : image Node figée, image construite une seule fois depuis un commit,
  identifiée par son sha et sa version, scripts idempotents, rollback = redéploiement d'une
  image existante.
- **Code métier non modifié** : les incidents sont détectés et traités par la chaîne de
  livraison (tests de contrat, smoke tests, healthchecks), jamais en changeant `src/`.

## Choix techniques

Voir [docs/CHOIX_TECHNIQUES.md](docs/CHOIX_TECHNIQUES.md).
