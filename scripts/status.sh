#!/usr/bin/env bash
# État d'un environnement : couleur active, version de secours, santé, historique.
# Usage : scripts/status.sh <staging|production>
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
load_env "${1:?usage: status.sh <staging|production>}"

echo "Environnement : $DEPLOY_ENV  (public $PUBLIC_URL, préversion $PREVIEW_URL)"
echo "Active        : $(state_get active_version '-') sur $(state_get active_color '-')"
echo "Secours       : $(state_get previous_version '-') sur $(state_get previous_color '-')"
echo
for color in blue green; do
  printf '  %-6s image %-28s état %s\n' "$color" "$IMAGE_REPO:$(state_get "$color.tag" '-')" "$(health_of "$color")"
done
printf '  %-6s %s\n' proxy "$(health_of proxy)"
echo
echo "Réponse publique :"
curl -s -i --max-time 3 "$PUBLIC_URL/api/version" | grep -iE '^(HTTP|x-cargoflow-color)|version' || echo "  (pas de réponse)"
echo
echo "Dernières opérations :"
tail -n 10 "$STATE_DIR/history.log" 2>/dev/null || echo "  (aucune)"
