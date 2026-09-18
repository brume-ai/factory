#!/usr/bin/env bash
# eva-relance.sh — le texte de la RELANCE d'EVA, s'il y a des décisions en
# attente ; RIEN sinon.
#
# POURQUOI CE SCRIPT EXISTE. La règle d'EVA (docs/v2-feature.md § 5) : relance
# toutes les quatre heures, jamais avant 8 h ni après 21 h (Europe/Paris), tant
# qu'une décision attend. Hermes porte des tâches cron ; en mode `--no-agent
# --script`, LE SCRIPT EST LE JOB : ce qu'il écrit sur stdout est livré tel quel
# en Slack, et UN STDOUT VIDE EST UN SILENCE (vérifié le 18 septembre 2026 sur
# Hermes 0.21.3). Le job est donc « 0 8,12,16,20 * * * », TZ=Europe/Paris, et
# ce script décide seul s'il y a quelque chose à dire — sans LLM, sans
# passerelle, sans risque qu'un modèle invente une décision qui n'attend pas.
#
# DÉTERMINISTE : le même état rend le même texte (eva-watch.sh --decisions est
# trié et sans horodatage). Une relance qui changerait de formulation à chaque
# fois ressemblerait à une nouvelle information ; celle-ci est reconnaissable
# et s'ignore en connaissance de cause.
#
# PROVISIONNÉ dans ~/.hermes/scripts/ d'EVA par le module Nix (nix/eva.nix),
# sous forme d'un shim qui lance CE fichier depuis le clone d'EVA
# (/workspace/tools/factory/bin/) : le script versionné reste la seule copie.
# Un échec de lecture (GitHub injoignable) ne rend RIEN sur stdout — pas une
# relance sur un état qu'on n'a pas lu — et le dit sur stderr.
#
# Code : 0, toujours (une relance qui échoue n'est pas une panne à réparer par
# cron ; le motif est sur stderr, dans le journal d'Hermes).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"

decisions="$(bash "$HERE/eva-watch.sh" --decisions)" || {
  echo "eva-relance: eva-watch.sh a rendu $? — pas de relance sur un état illisible" >&2
  exit 0
}
[ -n "$decisions" ] || exit 0

n=0; liste=""
while IFS=$'\t' read -r num titre _; do
  [ -n "${num:-}" ] || continue
  n=$((n+1))
  liste="$liste${liste:+, }$num $titre"
done <<< "$decisions"

if [ "$n" -eq 1 ]; then
  printf '1 décision t'"'"'attend : %s — réponds-moi ici et on la tranche.\n' "$liste"
else
  printf '%s décisions t'"'"'attendent : %s — réponds-moi ici et on les tranche une par une.\n' "$n" "$liste"
fi
exit 0
