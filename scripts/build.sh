#!/usr/bin/env bash
# Construction reproductible de l'image depuis une référence Git (hors CI).
#
# Usage : scripts/build.sh [ref_git]     (défaut : HEAD)
#   ex.   scripts/build.sh v1.2.0
#
# L'image est construite à partir du contenu committé (git archive), jamais
# depuis les fichiers locaux modifiés. Les tests sont lancés avant le build.
# Tag : <IMAGE_REPO>:<version de package.json> et <IMAGE_REPO>:<sha court>.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

REF="${1:-HEAD}"
IMAGE_REPO="${IMAGE_REPO:-cargoflow-api}"
SHA="$(git -C "$ROOT" rev-parse --short "$REF^{commit}")"
VERSION="$(git -C "$ROOT" show "$REF:package.json" | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p')"
[ -n "$VERSION" ] || die "version introuvable dans package.json ($REF)"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
git -C "$ROOT" archive "$REF" | tar -x -C "$WORKDIR"

log "Tests de $REF ($SHA, version $VERSION)"
(cd "$WORKDIR" && npm test --silent) || die "tests en échec, image non construite"

log "Build de $IMAGE_REPO:$VERSION"
docker build -q --build-arg APP_VERSION="$VERSION" \
  -t "$IMAGE_REPO:$VERSION" -t "$IMAGE_REPO:$SHA" "$WORKDIR" >/dev/null
log "Image prête : $IMAGE_REPO:$VERSION ($IMAGE_REPO:$SHA)"
