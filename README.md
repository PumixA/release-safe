# CargoFlow API

Ce dépôt contient l'API de devis de livraison utilisée dans le projet Release safe.

L'application fonctionne sans base de données.
Le travail porte sur les tests, le déploiement et le retour arrière.

## Démarrer

Avec Node.js 22 ou plus :

```bash
npm test
npm start
```

Ou avec Docker Compose :

```bash
docker compose up --build -d
```

## Vérifier

```bash
curl -i http://localhost:3000/healthz
curl -i http://localhost:3000/readyz
curl -i http://localhost:3000/api/version
curl -i "http://localhost:3000/api/quote?distanceKm=20&weightKg=3"
curl -i "http://localhost:3000/api/quote?distanceKm=120&weightKg=3"
```

Pour un colis de 3 kg, le devis attendu est de 13,60 € sur 20 km et de 53,60 € sur 120 km.

## Contenu du dépôt

- Une API HTTP sans dépendance npm externe.
- Un Dockerfile de départ, dont la sécurité reste à renforcer.
- Un fichier Compose qui lance une seule instance.
- Quatre tests de base.
- Un pipeline GitLab CI qui exécute uniquement les tests.

## Travail demandé

L'API démarre sur le port 3000.
L'infrastructure à réaliser devra exposer un point d'entrée public unique sur `http://localhost:8080`.

Le code métier ne doit pas être modifié pour contourner les incidents prévus dans l'exercice. 

Leur détection et leur résolution font partie du travail sur la livraison et l'exploitation.
