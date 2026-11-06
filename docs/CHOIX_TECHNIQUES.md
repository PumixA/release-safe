# Choix techniques

## GitHub Actions (et GitLab CI)

Le dépôt est hébergé sur GitHub ; le pipeline est `.github/workflows/ci-cd.yml`. GitHub apporte
dans le même outil le pipeline, le registry d'images (`ghcr.io`), les **environnements protégés**
(la production exige une approbation manuelle, l'historique des déploiements est visible dans
*Deployments*) et les groupes `concurrency` qui interdisent deux déploiements simultanés sur un
même environnement.

Les identifiants du registry sont fournis à chaque exécution (`GITHUB_TOKEN`, éphémère, droits
limités par job) : aucun secret n'est à stocker, ni dans le dépôt ni dans les paramètres.

Le dépôt fourni contenait un `.gitlab-ci.yml` : nous l'avons conservé et complété avec le même
pipeline pour GitLab. Toute la logique est dans `scripts/`, ce qui rend le pipeline portable :
seule l'orchestration diffère entre les deux plateformes.

**Runner auto-hébergé et dépôt public.** Les jobs de déploiement ne s'exécutent jamais sur une
pull request (seulement sur `main`, sur les tags et en déclenchement manuel), afin qu'un fork
ne puisse pas exécuter de code sur la machine de déploiement.

## Construire une fois, livrer partout

L'image est construite **une seule fois** par commit, taguée avec le sha court (et la version
sur un tag Git), puis c'est **la même image** qui est vérifiée, déployée en staging puis en
production. On évite ainsi de livrer en production autre chose que ce qui a été testé.

La version applicative est inscrite dans l'image au build (`APP_VERSION` et label OCI
`org.opencontainers.image.version`). Elle n'est plus définie dans le Compose : impossible
d'oublier de la mettre à jour, et les scripts savent quelle version `/api/version` doit
renvoyer pour n'importe quel tag d'image.

## Dockerfile

| Choix | Raison |
|---|---|
| `node:22.23-alpine3.24` (tag précis) | builds reproductibles, image légère |
| `USER node`, code appartenant à root | le processus ne peut pas modifier son propre code |
| `read_only`, `cap_drop: ALL`, `no-new-privileges` (Compose) | réduction de la surface d'attaque |
| `HEALTHCHECK` sur `/readyz` | `/healthz` indique seulement que le processus vit ; `/readyz` qu'il peut servir des devis |
| `.dockerignore` restrictif | ni tests, ni scripts, ni `.git` dans l'image |

## Blue/green avec Nginx

**Pourquoi Nginx plutôt que Traefik ?** La bascule doit être explicite et contrôlée par le
script, après vérification. Avec Nginx, la couleur active tient dans un fichier d'une ligne :
la bascule est atomique (`mv`), validée (`nginx -t`) et appliquée par un reload gracieux. Avec
Traefik, le routage par labels Docker suit la vie des conteneurs, ce qui rend plus difficile
de garder deux versions démarrées tout en n'en exposant qu'une, au moment choisi.

- `resolver 127.0.0.11` + `proxy_pass http://$active_color:3000` : les noms sont résolus à la
  requête, Nginx démarre même si une couleur est arrêtée.
- Port de **préversion** lié à `127.0.0.1` : la nouvelle version est testée à travers le
  même proxy que les clients, sans être exposée publiquement.
- En-tête `X-CargoFlow-Color` et couleur dans les logs d'accès : on voit qui a répondu.

**Pourquoi garder l'ancienne couleur démarrée ?** Le rollback devient une simple bascule
(~1 s), sans dépendre du registry ni d'un redémarrage.

## Vérifications à plusieurs niveaux

| Niveau | Contrôle | Ce qu'il attrape |
|---|---|---|
| CI `test` | tests fournis + tests de contrat de l'équipe | erreurs de barème, régressions HTTP |
| CI `verify` | l'image publiée démarre et passe le smoke test | image cassée, mauvaise version |
| Déploiement | healthcheck `/readyz` avec délai max | version qui ne démarre pas ou ne devient jamais prête |
| Avant bascule | smoke test via la préversion | comportement faux en conditions réelles (proxy, config) |
| Après bascule | smoke test public + observation | problème lié au trafic réel → rollback automatique |

Les tests de contrat sont la pièce clé : les tests fournis avec chaque version peuvent ne pas
couvrir un défaut (cas de la 1.1.0). Le contrat (barème, codes HTTP, format de réponse) est
détenu par l'équipe et ne change pas avec les livraisons.

## État des déploiements

L'état (couleur active, version de secours, tags des couleurs, historique) est stocké par les
scripts dans `.state/<env>/` en local, `/var/lib/cargoflow/<env>/` sur le serveur. Il n'est pas
versionné : il décrit le serveur, pas le code. Les écritures sont atomiques et un verrou
`flock` empêche les opérations concurrentes.

## Ce qu'on ferait en plus en production réelle

- Proxy en HTTPS, registry et runner dédiés.
- Métriques (taux de 5xx, latence) et alerting branchés sur l'observation post-bascule.
- Signature des images et scan de vulnérabilités dans le pipeline.
