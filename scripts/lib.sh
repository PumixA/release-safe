# Fonctions communes aux scripts de déploiement (sourcé, pas exécuté).
# shellcheck shell=bash
# Variables globales (ROOT, SCRIPTS, *_URL...) utilisées par les scripts appelants.
# shellcheck disable=SC2034

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$ROOT/scripts"

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die()  { log "ERREUR : $*" >&2; exit 1; }

# load_env <staging|production> : charge la configuration et l'état de l'environnement.
load_env() {
  case "${1:-}" in
    staging|production) ;;
    *) die "environnement inconnu '${1:-}' (attendu : staging ou production)" ;;
  esac
  # shellcheck disable=SC1090
  source "$ROOT/deploy/env/$1.env"

  # Dépôt d'images : registry GitLab en CI, image locale sinon.
  IMAGE_REPO="${IMAGE_REPO:-${CI_REGISTRY_IMAGE:-cargoflow-api}}"
  STATE_DIR="${CARGOFLOW_STATE_ROOT:-$ROOT/.state}/$DEPLOY_ENV"
  PUBLIC_URL="http://127.0.0.1:$PUBLIC_PORT"
  PREVIEW_URL="http://127.0.0.1:$PREVIEW_PORT"
  READY_TIMEOUT="${READY_TIMEOUT:-90}"
  mkdir -p "$STATE_DIR/nginx"

  BLUE_TAG="$(state_get blue.tag none)"
  GREEN_TAG="$(state_get green.tag none)"
  export IMAGE_REPO STATE_DIR PUBLIC_PORT PREVIEW_PORT BLUE_TAG GREEN_TAG
}

compose() {
  docker compose -p "$COMPOSE_PROJECT" -f "$ROOT/deploy/compose.yaml" "$@"
}

state_get() { # state_get <clé> [défaut]
  if [ -f "$STATE_DIR/$1" ]; then cat "$STATE_DIR/$1"; else printf '%s' "${2:-}"; fi
}

state_set() { # state_set <clé> <valeur> (écriture atomique)
  printf '%s' "$2" > "$STATE_DIR/.$1.tmp" && mv -f "$STATE_DIR/.$1.tmp" "$STATE_DIR/$1"
}

# image_version <tag> : version applicative inscrite dans l'image (label OCI).
# Permet de déployer par sha (staging) ou par version (production).
image_version() {
  local v
  v="$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$IMAGE_REPO:$1" 2>/dev/null || true)"
  printf '%s' "${v:-$1}"
}

other_color() { if [ "$1" = blue ]; then echo green; else echo blue; fi; }

# history <action> <version> <couleur> <résultat> : journal des livraisons.
history() {
  printf '%s | %-10s | %-14s | %-8s | %-5s | %-9s | par %s | commit %s\n' \
    "$(date -Iseconds)" "$DEPLOY_ENV" "$1" "$2" "$3" "$4" \
    "${GITLAB_USER_LOGIN:-${USER:-?}}" "${CI_COMMIT_SHORT_SHA:-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')}" \
    >> "$STATE_DIR/history.log"
}

# Un seul déploiement/rollback à la fois par environnement.
acquire_lock() {
  exec 9>"$STATE_DIR/.lock"
  flock -n 9 || die "une opération est déjà en cours sur $DEPLOY_ENV"
}

container_id() { compose ps -a -q "$1" 2>/dev/null; }

health_of() { # health_of <service> : healthy | unhealthy | starting | crashloop | exited | absent
  local id
  id="$(container_id "$1")"
  [ -n "$id" ] || { echo absent; return; }
  # Un conteneur qui a déjà redémarré a planté : inutile d'attendre le timeout.
  [ "$(docker inspect -f '{{.RestartCount}}' "$id")" -eq 0 ] || { echo crashloop; return; }
  docker inspect -f '{{if eq .State.Status "running"}}{{if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}{{else}}{{.State.Status}}{{end}}' "$id"
}

# wait_healthy <service> <timeout_s> : attend que le healthcheck (/readyz) passe.
wait_healthy() {
  local svc="$1" timeout="$2" start status
  start=$(date +%s)
  while :; do
    status="$(health_of "$svc")"
    case "$status" in
      healthy) log "$svc est prête (/readyz = 200) après $(( $(date +%s) - start ))s"; return 0 ;;
      unhealthy|crashloop|restarting|exited|dead|absent)
        log "$svc en échec (état : $status)"; compose logs --tail 20 "$svc" >&2; return 1 ;;
    esac
    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then
      log "$svc pas prête après ${timeout}s (état : $status)"; compose logs --tail 20 "$svc" >&2; return 1
    fi
    sleep 2
  done
}

# set_route <active|preview> <couleur> : réécrit la route Nginx puis recharge à chaud.
# Le reload est gracieux : les requêtes en cours se terminent sur l'ancienne couleur.
set_route() {
  local kind="$1" color="$2" file backup
  file="$STATE_DIR/nginx/$kind.conf"
  backup="$(cat "$file" 2>/dev/null || true)"
  printf 'set $%s_color %s;\n' "$kind" "$color" > "$file.tmp" && mv -f "$file.tmp" "$file"
  if ! compose exec -T proxy nginx -t -q; then
    printf '%s\n' "$backup" > "$file"
    die "configuration Nginx invalide, route $kind inchangée"
  fi
  compose exec -T proxy nginx -s reload 2>/dev/null
  # Laisse les nouveaux workers Nginx prendre le relais.
  sleep 1
}

# ensure_proxy : crée les routes par défaut et démarre Nginx si besoin.
ensure_proxy() {
  # $active_color / $preview_color sont des variables Nginx, pas shell.
  # shellcheck disable=SC2016
  [ -f "$STATE_DIR/nginx/active.conf" ]  || printf 'set $active_color blue;\n'   > "$STATE_DIR/nginx/active.conf"
  # shellcheck disable=SC2016
  [ -f "$STATE_DIR/nginx/preview.conf" ] || printf 'set $preview_color green;\n' > "$STATE_DIR/nginx/preview.conf"
  if [ "$(health_of proxy)" != healthy ]; then
    compose up -d --no-deps proxy >/dev/null
    for _ in $(seq 1 15); do
      curl -fsS -o /dev/null "$PUBLIC_URL/nginx-health" 2>/dev/null && return 0
      sleep 1
    done
    die "le proxy Nginx ne répond pas sur $PUBLIC_URL"
  fi
}

# observe <url> <secondes> <service> : surveille l'URL publique et le conteneur
# juste après la bascule. Un redémarrage du conteneur (crash) est un échec même si
# Docker l'a relancé assez vite pour que les requêtes HTTP ne le voient pas.
observe() {
  local url="$1" seconds="$2" svc="$3" end errors=0 code health
  end=$(( $(date +%s) + seconds ))
  log "Observation du trafic public et de $svc pendant ${seconds}s..."
  while [ "$(date +%s)" -lt "$end" ]; do
    health="$(health_of "$svc")"
    case "$health" in
      healthy) ;;
      *) log "  $svc : état $health"; return 1 ;;
    esac
    for path in /readyz "/api/quote?distanceKm=20&weightKg=3"; do
      code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$url$path" || true)
      [ "$code" = 200 ] || { errors=$((errors + 1)); log "  $path -> $code"; }
    done
    [ "$errors" -lt 3 ] || return 1
    sleep 2
  done
  [ "$errors" -eq 0 ]
}
