#!/usr/bin/env bash
# Vérification fonctionnelle d'une instance CargoFlow.
#
# Usage : scripts/smoke-test.sh <url> [version_attendue]
#   ex.   scripts/smoke-test.sh http://127.0.0.1:18080 1.2.0
#
# Code retour 0 si tous les contrôles passent, 1 sinon.
# Utilisé avant la bascule (préversion), après la bascule (URL publique) et en CI.
set -uo pipefail

BASE_URL="${1:?usage: smoke-test.sh <url> [version_attendue]}"
EXPECTED_VERSION="${2:-}"
# Temps de réponse maximum toléré (secondes).
# Devis > 100 km : ~12 s annoncées depuis la 1.2.0, on tolère 20 s.
FAST_TIMEOUT="${SMOKE_FAST_TIMEOUT:-2}"
LONG_TIMEOUT="${SMOKE_LONG_TIMEOUT:-20}"

failures=0
BODY=""

ok()   { printf '  [OK]   %s\n' "$1"; }
ko()   { printf '  [ECHEC] %s\n' "$1"; failures=$((failures + 1)); }

# request <timeout> <chemin> -> renseigne STATUS, BODY, TIME
request() {
  local out
  out=$(curl -sS --max-time "$1" -w '\n%{http_code} %{time_total}' "${BASE_URL}$2" 2>&1) || {
    STATUS="000"; TIME="$1"; BODY="$(printf '%s' "$out" | sed '$d')"; return 1; }
  BODY=$(printf '%s' "$out" | sed '$d')
  read -r STATUS TIME <<<"$(printf '%s' "$out" | tail -n1)"
}

json_field() { # json_field <champ> : extrait une valeur simple du JSON de BODY
  printf '%s' "$BODY" | sed -n "s/.*\"$1\":\"\{0,1\}\([^\",}]*\).*/\1/p"
}

expect_status() { # expect_status <libellé> <timeout> <chemin> <statut>
  if request "$2" "$3" && [ "$STATUS" = "$4" ]; then
    ok "$1 ($STATUS, ${TIME}s)"
  else
    ko "$1 : attendu $4, obtenu $STATUS (${TIME}s) $BODY"
  fi
}

expect_quote() { # expect_quote <distanceKm> <weightKg> <montant> <timeout>
  local label="devis $1 km / $2 kg = $3 EUR"
  if ! request "$4" "/api/quote?distanceKm=$1&weightKg=$2" || [ "$STATUS" != "200" ]; then
    ko "$label : statut $STATUS (${TIME}s) $BODY"; return
  fi
  local amount
  amount=$(json_field amountEUR)
  if awk -v a="$amount" -v b="$3" 'BEGIN { exit !(a != "" && a + 0 == b + 0) }'; then
    ok "$label (${TIME}s)"
  else
    ko "$label : montant obtenu '$amount'"
  fi
}

echo "Smoke test sur ${BASE_URL}${EXPECTED_VERSION:+ (version attendue ${EXPECTED_VERSION})}"

expect_status "processus vivant /healthz" "$FAST_TIMEOUT" /healthz 200
expect_status "instance prête /readyz" "$FAST_TIMEOUT" /readyz 200

if request "$FAST_TIMEOUT" /api/version && [ "$STATUS" = "200" ]; then
  version=$(json_field version)
  if [ -z "$EXPECTED_VERSION" ] || [ "$version" = "$EXPECTED_VERSION" ]; then
    ok "version exposée : $version"
  else
    ko "version exposée : '$version', attendue '$EXPECTED_VERSION'"
  fi
else
  ko "/api/version : statut $STATUS"
fi

# Barème de référence : 5 EUR + 0,40 EUR/km + 0,20 EUR/kg.
expect_quote 20 3 13.60 "$FAST_TIMEOUT"
expect_quote 100 3 45.60 "$FAST_TIMEOUT"
expect_quote 120 3 53.60 "$LONG_TIMEOUT"
expect_status "paramètres invalides rejetés" "$FAST_TIMEOUT" "/api/quote?distanceKm=-1&weightKg=2" 400
expect_status "route inconnue" "$FAST_TIMEOUT" /inconnue 404

if [ "$failures" -gt 0 ]; then
  echo "Smoke test : $failures contrôle(s) en échec."
  exit 1
fi
echo "Smoke test : tous les contrôles sont passés."
