#!/usr/bin/env bash
# Retour arrière de CargoFlow.
#
# Usage : scripts/rollback.sh <staging|production> [version]
#
# Sans version : rebascule instantanément sur la couleur de secours (version
#   précédente, toujours démarrée), après l'avoir revérifiée.
# Avec version, ou si la couleur de secours n'est plus disponible :
#   redéploie la version demandée (ou la précédente) depuis son image, avec
#   les mêmes contrôles qu'un déploiement normal (scripts/deploy.sh).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

ENV_NAME="${1:?usage: rollback.sh <staging|production> [version]}"
REQUESTED="${2:-}"
load_env "$ENV_NAME"

ACTIVE="$(state_get active_color)"
ACTIVE_VERSION="$(state_get active_version)"
PREVIOUS="$(state_get previous_color)"
PREVIOUS_VERSION="$(state_get previous_version)"

[ -n "$ACTIVE" ] || die "aucun déploiement sur $DEPLOY_ENV"
TARGET_VERSION="${REQUESTED:-$PREVIOUS_VERSION}"
[ -n "$TARGET_VERSION" ] || die "aucune version précédente connue, préciser : rollback.sh $DEPLOY_ENV <version>"

log "=== Rollback de $DEPLOY_ENV : $ACTIVE_VERSION ($ACTIVE) -> $TARGET_VERSION ==="

# Rollback instantané possible si la couleur de secours tourne encore avec la bonne version.
if [ -n "$PREVIOUS" ] && [ "$PREVIOUS" != "$ACTIVE" ] \
   && [ "$(state_get "$PREVIOUS.tag")" = "$TARGET_VERSION" ] \
   && [ "$(health_of "$PREVIOUS")" = healthy ]; then
  acquire_lock
  set_route preview "$PREVIOUS"
  "$SCRIPTS/smoke-test.sh" "$PREVIEW_URL" "$TARGET_VERSION" \
    || die "la couleur de secours $PREVIOUS ne passe pas le smoke test, rollback annulé (trafic inchangé)"

  log "Bascule du trafic public vers $PREVIOUS ($TARGET_VERSION)"
  set_route active "$PREVIOUS"
  state_set active_color "$PREVIOUS"
  state_set active_version "$TARGET_VERSION"
  state_set previous_color "$ACTIVE"
  state_set previous_version "$ACTIVE_VERSION"

  if "$SCRIPTS/smoke-test.sh" "$PUBLIC_URL" "$TARGET_VERSION"; then
    history rollback "$TARGET_VERSION" "$PREVIOUS" OK
    log "=== Rollback terminé : $TARGET_VERSION en service. $ACTIVE_VERSION reste démarrée sur $ACTIVE pour analyse. ==="
    exit 0
  fi
  history rollback "$TARGET_VERSION" "$PREVIOUS" ÉCHEC
  die "le smoke test public échoue après rollback"
fi

# Sinon : redéploiement reproductible de la version depuis son image.
log "Couleur de secours indisponible : redéploiement de $TARGET_VERSION depuis son image."
"$SCRIPTS/deploy.sh" "$DEPLOY_ENV" "$TARGET_VERSION"
history rollback "$TARGET_VERSION" "$(state_get active_color)" OK
