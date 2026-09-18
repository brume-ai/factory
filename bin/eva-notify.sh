#!/usr/bin/env bash
# eva-notify.sh — envoie en Slack, par EVA, ce qui vient d'apparaître dans la
# file d'attente humaine. NE BLOQUE JAMAIS LA BOUCLE.
#
# POURQUOI CE SCRIPT EXISTE. L'usine sait qu'elle attend un humain et ne le
# disait qu'à journald (docs/v2-feature.md, en tête). Ce script est le pont :
# `eva-watch.sh --diff` rend les NOUVEAUTÉS (et seulement elles — le tour
# suivant ne répète rien), et `eva send -t slack -f -` les poste dans le canal
# home d'EVA sans passerelle ni LLM (Hermes `send`, vérifié le 18 septembre
# 2026 sur Hermes 0.21.3). Pas de digest : un ping par nouveauté, au tour où
# elle apparaît.
#
# APPEL ATTENDU : par le TIMER HÔTE `factory-eva-notify` (nix/eva.nix), toutes
# les deux minutes, sous l'utilisateur d'usine, avec FACTORY_ROOT = l'arbre de
# la boucle, EVA_GITHUB_DIR = les identifiants d'EVA (le ping est lu avec son
# jeton) et FACTORY_EVA_SEND = le wrapper `eva`. Pas par la boucle : elle
# tourne dans le conteneur factory-loop, où le wrapper n'existe pas. Ce script
# rend TOUJOURS 0 : un envoi qui échoue, un `eva` absent, un GitHub injoignable
# se disent sur stderr (le journal de l'unité) et c'est tout — l'usine tourne
# sans EVA, elle ne s'arrête pas parce qu'EVA ne parle pas.
#
# « VU » N'EST ÉCRIT QU'APRÈS L'ENVOI. `--diff` écrit l'état PROPOSÉ dans
# watch.json.pending ; ce script le promeut en watch.json seulement quand
# `eva send` a rendu 0. Un envoi raté laisse l'état d'avant : au passage
# suivant, les mêmes nouveautés repartent. Marquer avant d'envoyer perdait une
# « PR prête », une « CI rouge », une « boucle arrêtée » pour toujours au
# premier hoquet de Slack.
#
# L'EXPÉDITEUR EST VÉRIFIÉ AVANT DE LIRE. Absent, on le dit UNE fois (marqueur
# à côté de l'état, effacé quand l'expéditeur revient) et on ne lit rien : le
# jour où `eva` apparaît, tout ce qui attendait part d'un coup.
#
# FACTORY_EVA_SEND remplace le binaire `eva` (tests, ou un expéditeur qui n'est
# pas Hermes). Il reçoit `send -t slack -f -` et le texte sur stdin.
#
# Code : 0, toujours.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
. "$HERE/lib.sh"

SEND="${FACTORY_EVA_SEND:-eva}"
STATE_FILE="$(conf_get FACTORY_EVA_STATE "$(conf_get FACTORY_STATE /srv/factory)/eva/watch.json")"
MARK="${STATE_FILE%/*}/send-absent"

if ! command -v "$SEND" >/dev/null 2>&1; then
  if [ ! -f "$MARK" ]; then
    echo "eva-notify: « $SEND » introuvable — l'usine tourne sans EVA, personne ne sera prévenu en Slack (dit une fois ; FACTORY_EVA_SEND pour désigner l'expéditeur)" >&2
    mkdir -p "${MARK%/*}" 2>/dev/null && : > "$MARK"
  fi
  exit 0
fi
rm -f "$MARK"

news="$(bash "$HERE/eva-watch.sh" --diff)" || {
  echo "eva-notify: eva-watch.sh a rendu $? — rien d'envoyé ce tour-ci" >&2
  exit 0
}
PENDING="$STATE_FILE.pending"
if [ -z "$news" ]; then
  # Rien de nouveau : l'état proposé ne fait qu'oublier ce qui a disparu, on
  # le promeut sans rien envoyer.
  [ ! -f "$PENDING" ] || mv -f "$PENDING" "$STATE_FILE"
  exit 0
fi

if printf '%s\n' "$news" | "$SEND" send -t slack -f - >/dev/null; then
  mv -f "$PENDING" "$STATE_FILE" 2>/dev/null || echo "eva-notify: envoyé, mais l'état $STATE_FILE n'a pas pu être écrit — les mêmes nouveautés repartiront" >&2
  echo "eva-notify: $(printf '%s\n' "$news" | wc -l | tr -d ' ') nouveauté(s) envoyée(s) en Slack" >&2
else
  echo "eva-notify: l'envoi Slack a échoué (code $?) — rien n'est marqué vu, ces nouveautés repartiront au prochain passage :" >&2
  printf '%s\n' "$news" >&2
  rm -f "$PENDING"
fi
exit 0
