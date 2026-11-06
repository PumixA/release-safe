# Image de production de l'API CargoFlow.
# Version de Node figée (mineure + Alpine) pour des builds reproductibles.
FROM node:22.23-alpine3.24

# La version livrée est inscrite dans l'image au build (cf. CI) :
# /api/version renvoie toujours la version réellement déployée.
ARG APP_VERSION=dev
ENV NODE_ENV=production \
    PORT=3000 \
    APP_VERSION=${APP_VERSION}

LABEL org.opencontainers.image.title="cargoflow-api" \
      org.opencontainers.image.version="${APP_VERSION}"

WORKDIR /app

# Fichiers appartenant à root et en lecture seule pour l'utilisateur
# d'exécution : le processus ne peut pas modifier son propre code.
COPY package.json ./
COPY src ./src

# Utilisateur non privilégié fourni par l'image node.
USER node

EXPOSE 3000

# Healthcheck sur /readyz (prêt à servir des devis) et non sur /healthz
# (simple processus vivant).
HEALTHCHECK --interval=5s --timeout=3s --start-period=10s --retries=3 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:3000/readyz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]

STOPSIGNAL SIGTERM
CMD ["node", "src/index.js"]
