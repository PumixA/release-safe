#!/usr/bin/env bash
# Déploiement blue/green d'une version de CargoFlow.
#
# Usage : scripts/deploy.sh <staging|production> <tag_image>
#   ex.   scripts/deploy.sh production 1.2.0
#         scripts/deploy.sh staging 3f2a9c1      (sha court, construit par la CI)
#
# Étapes :
#   1. démarre la version sur la couleur inactive (l'autre continue de servir) ;
#   2. attend qu'elle soit prête (/readyz) ;
#   3. la vérifie via le port de préversion (smoke test) ;
#      -> en cas d'échec : arrêt, AUCUNE bascule, le service reste sur l'ancienne version ;
#   4. bascule Nginx (reload gracieux, sans coupure) ;
#   5. revérifie via l'URL publique puis observe le trafic ;
#      -> en cas d'échec : retour automatique à l'ancienne couleur.
# L'ancienne couleur reste démarrée pour un rollback instantané (scripts/rollback.sh).
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

ENV_NAME="${1:?usage: deploy.sh <staging|production> <version>}"
VERSION="${2:?usage: deploy.sh <staging|production> <version>}"

load_env "$ENV_NAME"
acquire_lock

IMAGE="$IMAGE_REPO:$VERSION"
log "=== Déploiement de $IMAGE sur $DEPLOY_ENV ==="

# L'image doit exister (construite et testée par la CI). Rien n'est construit ici.
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  log "Récupération de $IMAGE..."
  docker pull -q "$IMAGE" >/dev/null || die "image $IMAGE introuvable"
fi
APP_VERSION="$(image_version "$VERSION")"
log "Version applicative attendue : $APP_VERSION"

ensure_proxy

ACTIVE="$(state_get active_color)"
ACTIVE_VERSION="$(state_get active_version)"
PREVIOUS_COLOR="$(state_get previous_color)"
PREVIOUS_VERSION="$(state_get previous_version)"
if [ -n "$ACTIVE" ] && [ "$ACTIVE_VERSION" = "$VERSION" ] && [ "$(health_of "$ACTIVE")" = healthy ]; then
  log "$VERSION est déjà la version active ($ACTIVE). Rien à faire."
  exit 0
fi

if [ -n "$ACTIVE" ]; then TARGET="$(other_color "$ACTIVE")"; else TARGET=blue; fi
log "Version active : ${ACTIVE_VERSION:-aucune} (${ACTIVE:-aucune couleur}) -> cible : $TARGET"

reject() { # Échec avant bascule : la production n'a jamais vu la nouvelle version.
  log "RELEASE REJETÉE : $1"
  log "Le trafic reste sur ${ACTIVE_VERSION:-aucune version} (${ACTIVE:-aucune}). Arrêt de $TARGET (logs conservés)."
  compose stop "$TARGET" >/dev/null 2>&1 || true
  history deploy "$VERSION" "$TARGET" REJETÉE
  exit 1
}

# 1. Démarrage de la nouvelle version sur la couleur inactive.
state_set "$TARGET.tag" "$VERSION"
if [ "$TARGET" = blue ]; then export BLUE_TAG="$VERSION"; else export GREEN_TAG="$VERSION"; fi
compose up -d --no-deps --force-recreate "$TARGET"

# 2. Disponibilité.
wait_healthy "$TARGET" "$READY_TIMEOUT" || reject "$TARGET n'est jamais devenue prête"

# 3. Vérification avant bascule, via la préversion (127.0.0.1 uniquement).
set_route preview "$TARGET"
log "Vérification de $TARGET via la préversion $PREVIEW_URL"
"$SCRIPTS/smoke-test.sh" "$PREVIEW_URL" "$APP_VERSION" || reject "smoke test en échec sur $TARGET"

# 4. Bascule.
log "Bascule du trafic public vers $TARGET ($VERSION)"
set_route active "$TARGET"
state_set active_color "$TARGET"
state_set active_version "$VERSION"
if [ -n "$ACTIVE" ]; then
  state_set previous_color "$ACTIVE"
  state_set previous_version "$ACTIVE_VERSION"
fi

# 5. Vérification après bascule et observation.
if "$SCRIPTS/smoke-test.sh" "$PUBLIC_URL" "$APP_VERSION" && observe "$PUBLIC_URL" "${OBSERVE_SECONDS:-10}"; then
  history deploy "$VERSION" "$TARGET" OK
  log "=== $VERSION en service sur $DEPLOY_ENV ($TARGET). Version précédente gardée en secours : ${ACTIVE_VERSION:-aucune} (${ACTIVE:-aucune}) ==="
  exit 0
fi

log "Échec après bascule."
if [ -z "$ACTIVE" ]; then
  history deploy "$VERSION" "$TARGET" ÉCHEC
  die "premier déploiement en échec, aucune version précédente vers laquelle revenir"
fi
log "ROLLBACK AUTOMATIQUE vers $ACTIVE_VERSION ($ACTIVE)"
set_route active "$ACTIVE"
set_route preview "$ACTIVE"
state_set active_color "$ACTIVE"
state_set active_version "$ACTIVE_VERSION"
state_set previous_color "$PREVIOUS_COLOR"
state_set previous_version "$PREVIOUS_VERSION"
compose stop "$TARGET" >/dev/null 2>&1 || true
history deploy "$VERSION" "$TARGET" ROLLBACK
"$SCRIPTS/smoke-test.sh" "$PUBLIC_URL" "$(image_version "$ACTIVE_VERSION")" || log "ATTENTION : la version restaurée ne passe pas le smoke test"
exit 1
