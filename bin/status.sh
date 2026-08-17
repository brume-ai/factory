#!/usr/bin/env bash
# Extrait de Brume (tools/factory/status.sh) au SHA 12ac9e92 ; generalise ici.
# status.sh — l'état de l'usine en un coup d'œil, depuis un poste.
#
# CE QU'ON VEUT SAVOIR d'une machine qui travaille sans surveillance : est-ce
# qu'elle tourne, qu'est-ce qu'elle fait EN CE MOMENT, qu'a-t-elle livré depuis
# hier, et est-ce que quelque chose cloche. Quatre questions, une commande.
#
# PAS DE NOUVEAU FICHIER DE LOG, délibérément. Le journal de systemd est déjà
# persistant sur l'usine (`/var/log/journal`), déjà daté, et il se purge tout
# seul. Écrire une copie à côté donnerait deux vérités dont une seule est
# entretenue — et c'est toujours celle qu'on lit qui est périmée. Ce script LIT
# ce journal et en tire un état ; `make factory-log` en donne le flux brut.
#
# LA BOUCLE TOURNE EN MODE SILENCIEUX, et c'est ce qui rend ce résumé possible :
# `claude -p` sans `--output-format` n'imprime que son message FINAL, donc le
# journal contient un rapport par carte au lieu de mégaoctets d'appels d'outils.
# Passer la boucle en VERBOSE=1 rendrait ce digest illisible.
#
#   bash tools/factory/status.sh            # deux derniers jours
#   SINCE='7 days ago' CARDS=15 …/status.sh # fenêtre plus large
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
FACTORY_NAME="$(conf_get FACTORY_NAME usine)"
FACTORY_HOST="$(conf_get FACTORY_HOST)"; conf_require FACTORY_HOST FACTORY_KEY
STATE="$(conf_get FACTORY_STATE /srv/factory)"

SINCE="${SINCE:-2 days ago}"
CARDS="${CARDS:-6}"

B="$(tput bold 2>/dev/null || true)"; C="$(tput setaf 6 2>/dev/null || true)"
D="$(tput dim 2>/dev/null || true)"; R="$(tput sgr0 2>/dev/null || true)"

# UN SEUL ALLER-RETOUR. Chaque `ssh` coûte une poignée de secondes d'établissement
# de session ; en enchaîner six pour six questions rendrait la commande assez
# lente pour qu'on cesse de la taper, ce qui est la seule façon de rater ce
# qu'elle sert à voir. Le distant reste bête : il émet des sections, le tri se
# fait ici où il s'itère sans redéployer.
raw="$(factory_ssh "SINCE=\"$SINCE\" STATE=\"$STATE\" bash -s" <<'REMOTE'
set -uo pipefail
echo "::unit::"
# PAS de `--value` : systemd rend les propriétés dans SON ordre, pas dans celui
# demandé, donc les lire par position attribue la valeur d'un champ à un autre —
# ici « boucle 0 » au lieu de « boucle active », un état FAUX qui a l'air d'un
# état. Avec les clés, l'ordre n'a plus d'importance.
systemctl show factory-loop -p ActiveState -p NRestarts -p ActiveEnterTimestamp 2>/dev/null
echo "::container::"
docker ps -a --filter 'name=^factory-loop$' --format '{{.State}}\t{{.Status}}' 2>/dev/null
echo "::disk::"
df -h --output=pcent,avail "$STATE" 2>/dev/null | tail -1
echo "::auth::"
for a in claude codex gemini; do
  d="$STATE/secrets/$a-home"
  compgen -G "$d/*" >/dev/null 2>&1 && printf '%s ' "$a" || printf '%s(ABSENT) ' "$a"
done
echo
echo "::journal::"
# `-q` coupe l'avertissement « vous ne voyez pas les messages des autres
# utilisateurs » : l'unité tourne en `factory`, donc ses propres lignes sont
# visibles sans sudo, et cette note-là ne ferait que polluer l'analyse.
journalctl -u factory-loop -q --no-pager -o short-iso --since "$SINCE" 2>/dev/null
REMOTE
)" || { echo "factory-status: $FACTORY_HOST injoignable en SSH." >&2; exit 3; }

section() { printf '%s\n' "$raw" | sed -n "/^::$1::$/,/^::/p" | sed '1d;/^::/d'; }

unit="$(section unit)"
val() { printf '%s\n' "$unit" | sed -n "s/^$1=//p" | tail -1; }
state="$(val ActiveState)"; nrestarts="$(val NRestarts)"; since_ts="$(val ActiveEnterTimestamp)"
IFS=$'\t' read -r _ cstatus <<<"$(section container)"
read -r pcent avail <<<"$(section disk)"
auth="$(section auth)"

# Le journal, débarrassé du préfixe syslog et des couleurs. Les échappements ANSI
# n'apparaissent que si la boucle a été lancée depuis un terminal — sous systemd,
# `tput` échoue faute de TERM et les variables de couleur sont vides. Les deux cas
# existent donc dans le même journal ; on nettoie sans se demander lequel.
log="$(section journal \
  | sed -E 's/\x1b\[[0-9;]*[mK]//g; s/^([0-9T:+-]+) [^ ]+ [^:]+: ?//' )"

human() {  # secondes → « 47s », « 12min », « 2h14 », « 3j »
  local s="$1"
  if   (( s < 90 ));    then printf '%ds' "$s"
  elif (( s < 5400 ));  then printf '%dmin' "$((s/60))"
  elif (( s < 172800 ));then printf '%dh%02d' "$((s/3600))" "$(((s%3600)/60))"
  else printf '%dj' "$((s/86400))"; fi
}
now="$(date +%s)"
ago() { local t; t="$(date -d "$1" +%s 2>/dev/null)" || { printf '?'; return; }; human "$((now-t))"; }

echo
if [[ "$state" == "active" ]]; then
  printf '%susine %s%s — boucle %sactive%s depuis %s · conteneur %s · %s redémarrage(s)\n' \
    "$B" "$FACTORY_NAME" "$R" "$C" "$R" "$(ago "$since_ts")" "${cstatus:-absent}" "${nrestarts:-?}"
else
  printf '%susine %s%s — boucle %s%s%s (conteneur %s)\n' \
    "$B" "$FACTORY_NAME" "$R" "$B" "${state:-inconnue}" "$R" "${cstatus:-absent}"
  printf '  %ssudo systemctl start factory-loop%s pour la relancer\n' "$D" "$R"
fi

# --- ce qu'elle fait, et ce qu'elle a fait -----------------------------------
# Une CARTE commence à un marqueur `— issue #N —` / `— entretien : PR #N —`, et
# se termine à la première ligne de MÉCANIQUE qui suit (le ménage du tour
# suivant). Entre les deux, tout ce qui n'est ni marqueur ni mécanique est le
# rapport final de l'agent. Ce découpage tient parce que la boucle encadre
# chaque tour de ses propres lignes — il n'y a pas à demander à l'agent de
# baliser quoi que ce soit, donc rien qu'il puisse oublier de faire.
digest="$(section journal \
  | sed -E 's/\x1b\[[0-9;]*[mK]//g' \
  | sed -E 's/^([0-9T:+-]+) [^ ]+ [^:]+: ?/\1\t/' \
  | awk -F'\t' -v max="$CARDS" '
  function flush(   r) {
    # Le rapport est du markdown écrit pour un humain : sur une ligne de terminal
    # tronquée, les astérisques de gras et les puces ne servent plus à rien.
    r = rep; gsub(/\*\*|^#+ |`/, "", r); gsub(/  +/, " ", r)
    if (length(r) > 120) r = substr(r, 1, 119) "…"
    if (id != "") { lines[++n] = start "\t" id "\t" endt "\t" r }
    id = ""; rep = ""; endt = ""
  }
  { ts = $1; msg = $2 }
  msg ~ /^— (issue|entretien|reprise)/ {
    flush(); start = ts; id = msg
    sub(/^— /, "", id); sub(/ —$/, "", id)
    sub(/^entretien : /, "", id); sub(/^reprise : carte /, "", id)
    next
  }
  msg ~ /^(wt-cleanup|gh-unblock|gh-pr-attention|wt-resume|gh-next-issue|run-loop|github-loop):/ ||
  msg ~ /^— / { if (id != "" && endt == "") endt = ts; next }
  { if (id != "" && endt == "" && msg ~ /[a-zA-Z]/ && length(rep) < 190) rep = rep (rep ? " " : "") msg }
  END { flush(); for (i = (n > max ? n - max + 1 : 1); i <= n; i++) print lines[i] }
')"

# EN COURS = la dernière carte ouverte dont aucune ligne de mécanique n'a signé la
# fin. Sans cette distinction, une carte affichée « en cours » resterait vraie
# éternellement après un agent tué — exactement le cas où l'on regarde.
current=""; current_ts=""
if [[ -n "$digest" ]]; then
  IFS=$'\t' read -r c_ts c_id c_end _ <<<"$(printf '%s\n' "$digest" | tail -1)"
  [[ -z "$c_end" ]] && { current="$c_id"; current_ts="$c_ts"; }
fi

printf '\n  %sen ce moment%s   ' "$B" "$R"
if [[ -n "$current" ]]; then
  printf '%s — depuis %s\n' "$C$current$R" "$(ago "$current_ts")"
else
  poll="$(printf '%s\n' "$(section journal)" | grep -- '— file vide' | tail -1 | cut -d' ' -f1)"
  if [[ -n "$poll" ]]; then
    printf 'aucune carte — file vide, dernier sondage il y a %s\n' "$(ago "$poll")"
  else
    printf 'aucune carte en cours\n'
  fi
fi

delivered="$(printf '%s\n' "$log" | sed -n 's/^gh-next-issue: déjà livrées (PR ouverte) : //p' | tail -1)"
[[ -n "$delivered" ]] && printf '  %slivrées%s        %s %s(PR ouvertes, en attente de merge)%s\n' \
  "$B" "$R" "$(printf '#%s' "${delivered//, / #}")" "$D" "$R"

if [[ -n "$digest" ]]; then
  printf '\n  %scartes récentes%s\n' "$B" "$R"
  while IFS=$'\t' read -r ts id end rep; do
    secs=0
    [[ -n "$end" ]] && secs=$(( $(date -d "$end" +%s) - $(date -d "$ts" +%s) ))
    # UN TOUR D'AGENT DURE DES MINUTES. Une « carte » de quelques secondes sans
    # le moindre rapport n'est pas du travail : c'est un marqueur que la boucle
    # a posé puis dépassé (le cas `— reprise` , suivi aussitôt du vrai marqueur
    # de carte). L'afficher ferait croire à un tour raté toutes les nuits.
    [[ -z "$rep" && "$secs" -lt 15 ]] && continue
    printf '    %s%s%s  %s  %s%s%s\n' \
      "$D" "$(date -d "$ts" '+%d/%m %H:%M')" "$R" "$id" "$D" "$([[ -n "$end" ]] && human "$secs" || echo 'en cours')" "$R"
    printf '                 %s%s%s\n' "$D" "${rep:-— aucun rapport —}" "$R"
  done <<<"$digest"
fi

# --- santé --------------------------------------------------------------------
# Trois pannes seulement, mais ce sont CELLES QUI ARRÊTENT L'USINE en silence :
# la session de l'agent expirée, le disque plein, une configuration cassée au
# sondage. Chacune se présente comme une file vide — l'usine a l'air d'attendre
# du travail alors qu'elle ne peut plus en prendre.
printf '\n  %ssanté%s          /srv/factory %s utilisé, %s libres · agents : %s\n' \
  "$B" "$R" "${pcent:-?}" "${avail:-?}" "${auth:-?}"

incidents="$(printf '%s\n' "$log" | grep -E 'configuration cassée|jeton dApp impossible|sans avancer : arrêt|Invalid API key|not logged in|Credit balance|401 ' | tail -3 || true)"
if [[ -n "$incidents" ]]; then
  printf '                 %sincidents :%s\n' "$C" "$R"
  printf '                   %s\n' "$incidents"
else
  printf '                 aucun incident depuis « %s »\n' "$SINCE"
fi

printf '\n  %smake factory-log%s le journal complet · %smake factory-log FOLLOW=1%s en direct\n\n' \
  "$D" "$R" "$D" "$R"
