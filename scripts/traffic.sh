#!/usr/bin/env bash
# Génère du trafic client pendant un déploiement pour prouver l'absence de coupure.
#
# Usage : scripts/traffic.sh <url> <secondes>
#   ex.   scripts/traffic.sh http://localhost:8080 90 &
#         scripts/deploy.sh production 1.2.0
#
# Envoie en continu des devis courts (20 km) et, toutes les 5 s, un devis long
# (120 km, ~12 s depuis la 1.2.0) qui sera souvent en cours au moment de la bascule.
# Affiche le nombre de réponses par code HTTP et par couleur ; code retour 1 si
# une seule requête a échoué.
set -uo pipefail

URL="${1:?usage: traffic.sh <url> <secondes>}"
DURATION="${2:?usage: traffic.sh <url> <secondes>}"
OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

hit() { # hit <type> <requête>
  local res
  res=$(curl -s -o /dev/null -D - --max-time 30 -w 'STATUS %{http_code}\n' "$URL/api/quote?$2" \
        | awk -v t="$1" 'tolower($1)=="x-cargoflow-color:" {c=$2} $1=="STATUS" {s=$2} END {gsub("\r","",c); print t, s, (c==""?"-":c)}')
  echo "$res" >> "$OUT"
  case "$res" in *" 200 "*) ;; *) echo "[$(date +%T)] $res" >&2 ;; esac
}

end=$(( $(date +%s) + DURATION ))
next_long=0
while [ "$(date +%s)" -lt "$end" ]; do
  if [ "$(date +%s)" -ge "$next_long" ]; then
    hit long "distanceKm=120&weightKg=3" &
    next_long=$(( $(date +%s) + 5 ))
  fi
  hit court "distanceKm=20&weightKg=3"
  sleep 0.2
done
wait

echo "Trafic sur $URL pendant ${DURATION}s :"
sort "$OUT" | uniq -c | awk '{printf "  %5d  %-6s HTTP %s  couleur %s\n", $1, $2, $3, $4}'
errors=$(awk '$2 != "200"' "$OUT" | wc -l)
echo "Requêtes en erreur : $errors / $(wc -l < "$OUT")"
[ "$errors" -eq 0 ]
