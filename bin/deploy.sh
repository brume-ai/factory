#!/usr/bin/env bash
# Extrait de Brume (tools/factory/deploy.sh) au SHA 12ac9e92 ; generalise ici.
# deploy.sh — met le dépôt de l'usine au niveau de `origin/main`.
#
# POURQUOI CE N'EST PAS UN `git pull` LANCÉ À LA MAIN. Le dépôt est privé et le
# distant ne porte aucun identifiant : sans jeton frappé au vol, un `pull` sur
# l'usine répond 403. Et l'outillage de la boucle est versionné AVEC le produit
# — `make loop` refuse d'ailleurs de tourner hors du tronc pour cette raison —
# donc une usine en retard exécute la version d'avant le dernier correctif, sans
# que rien ne le signale : elle a l'air de marcher.
#
# `reset --hard` et pas `pull`, comme install.sh : l'usine n'a pas de travail
# local à préserver dans son arbre principal — les cartes vivent dans des
# worktrees. Un `pull` y produirait un conflit de fusion qu'aucun humain ne
# viendrait résoudre.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
FACTORY_NAME="$(conf_get FACTORY_NAME usine)"
FACTORY_HOST="$(conf_get FACTORY_HOST)"; conf_require FACTORY_HOST FACTORY_KEY
STATE="$(conf_get FACTORY_STATE /srv/factory)"
conf_require GH_REPO
REPO_DIR="$(conf_get FACTORY_REPO_DIR "$(conf_get FACTORY_STATE /srv/factory)/workspace/$(basename "$(conf_get GH_REPO)")")"
TRUNK="$(conf_get FACTORY_TRUNK main)"

B="$(tput bold 2>/dev/null || true)"; C="$(tput setaf 6 2>/dev/null || true)"
D="$(tput dim 2>/dev/null || true)"; R="$(tput sgr0 2>/dev/null || true)"

echo
printf '%susine %s%s — déploiement de origin/main\n\n' "$B" "$FACTORY_NAME" "$R"

factory_ssh "REPO_DIR='$REPO_DIR' TRUNK='$TRUNK' bash -s" <<'REMOTE'
set -euo pipefail
cd "$REPO_DIR"

before="$(git rev-parse --short HEAD)"

# Le jeton est frappé par le script VERSIONNÉ, celui-là même que la boucle
# utilise. install.sh en garde une copie inline, mais uniquement pour l'amorçage
# — le dépôt n'existe pas encore quand il tourne. Ici il existe : pas de seconde
# implémentation à entretenir.
GH_TOKEN="$(bash tools/factory/bin/gh-app-token.sh)"
[[ -n "$GH_TOKEN" ]] || { echo "deploy: jeton d'App impossible à frapper" >&2; exit 3; }

# Le jeton n'entre JAMAIS dans l'URL du remote ni dans .git/config : il expire en
# une heure, et un secret périmé laissé là finit par être lu comme la cause d'un
# 401 qu'il n'explique pas. `git -c` ne vaut que pour cette commande.
git -c "http.https://github.com/.extraheader=Authorization: Basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 -w0)" \
    fetch --quiet origin
git reset --hard --quiet "origin/$TRUNK"

# LE POINTEUR DU SUBMODULE A BOUGÉ AVEC LE TRONC, PAS SON CONTENU. `reset --hard`
# écrit le gitlink ; l'arbre de travail du submodule, lui, reste au commit d'avant
# — ou vide, si le dépôt vient tout juste d'acquérir ce submodule. La boucle
# exécuterait alors l'outillage d'avant le dernier correctif, ou pas d'outillage
# du tout : `make loop` s'arrête sur « l'usine partagée n'est pas déployée », et
# c'est le DÉPLOIEMENT qui aurait dû le dire.
#
# AVANT la comparaison before/after, délibérément : un déploiement qui ne change
# pas le tronc doit quand même réparer un submodule laissé à moitié par un run
# interrompu. Sinon « déjà à jour » devient le message d'une machine cassée.
#
# PAS DE `|| true`, contrairement au tour de boucle (`factory.mk`) : la boucle
# tolère un outillage figé parce qu'elle tourne quand même ; `deploy` PROMET une
# machine à jour, et un submodule non initialisé après un déploiement réussi est
# exactement le mensonge que ce script existe pour ne pas dire.
#
# Le même en-tête d'autorisation que le fetch : un submodule privé vit dans la
# même installation d'App, et `git -c` se transmet aux fetch enfants.
if [[ -f .gitmodules ]]; then
  git -c "http.https://github.com/.extraheader=Authorization: Basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 -w0)" \
      submodule update --init --recursive --quiet
fi

after="$(git rev-parse --short HEAD)"

if [[ "$before" == "$after" ]]; then
  echo "  déjà à jour ($after)"
  exit 0
fi
echo "  $before → $after"
git log --oneline --no-decorate "$before..$after" | sed 's/^/    /'

# LE REDÉMARRAGE NE VA PAS DE SOI. Les scripts sont relus à chaque appel, donc un
# correctif dans `tools/factory/*.sh` prend effet au tour suivant sans rien
# faire. Le Makefile, lui, est lu UNE FOIS par le `make loop` qui tourne : sa
# recette vit en mémoire jusqu'à la fin du processus. Une usine mise à jour sans
# redémarrage exécute donc un mélange des deux versions.
#
# On ne redémarre QUE si la boucle dort. `systemctl restart` coupe le conteneur,
# donc l'agent avec : le faire pendant une carte jette un tour de travail
# entamé, et c'est exactement le moment où l'on est pressé de déployer.
# La preuve du sommeil est la dernière ligne du journal — la boucle annonce son
# attente avant de dormir, et ne dit plus rien tant qu'un agent travaille.
last="$(journalctl -u factory-loop -q --no-pager -o short-iso -n 1 2>/dev/null || true)"
last_ts="$(printf '%s' "$last" | cut -d' ' -f1)"
age=9999
[[ -n "$last_ts" ]] && age=$(( $(date +%s) - $(date -d "$last_ts" +%s) ))

if printf '%s' "$last" | grep -q 'file vide' && (( age < 120 )); then
  sudo -n systemctl restart factory-loop
  echo "  boucle redémarrée (elle dormait) — le nouveau Makefile est en vigueur"
else
  echo "  boucle NON redémarrée : une carte est en cours."
  echo "  Les scripts sont déjà actifs ; le Makefile le sera au prochain redémarrage :"
  echo "    factory ssh 'sudo systemctl restart factory-loop'"
fi
REMOTE

printf '\n  %sfactory%s pour voir où elle en est\n\n' "$D" "$R"
