#!/usr/bin/env bash
# Extrait de Brume (tools/factory/push-env.sh) au SHA 12ac9e92 ; generalise ici.
# push-env.sh — compose le .env de l'usine à partir du .env RACINE et le pose
# sur le volume persistant de la VM.
#
# TOURNE SUR UN POSTE, jamais sur l'usine : c'est ici qu'est le .env de
# référence. L'usine n'en reçoit qu'une projection.
#
#   bash tools/factory/push-env.sh
#
# POURQUOI UNE PROJECTION ET PAS UNE COPIE. L'usine exécute des agents en
# autonomie sur du code qui vient d'issues. Lui donner le .env intégral, c'est
# lui donner l'accès opérateur : kubeconfig de production, DSN de la base de
# prod, mot de passe sudo du NAS. Aucun de ces accès ne sert à mener une carte ;
# tous élargissent le rayon d'explosion d'un agent qui déraille. On retire donc
# le bloc « accès opérateur » du .env.example, et lui seul.
#
# LE FILTRE EST UNE LISTE DE REFUS, PAS D'AUTORISATION, et c'est un arbitrage
# assumé : une liste d'autorisation casserait l'usine à chaque variable ajoutée
# au produit (panne bruyante, mais permanente et à répétition), là où une liste
# de refus laisse passer un secret d'exploitation ajouté plus tard (panne
# silencieuse, mais rare et rattrapable). Le prix de la liste de refus est
# qu'elle DOIT être relue quand on ajoute un accès opérateur au .env — le
# garde-fou par motif ci-dessous attrape les familles évidentes, pas les noms
# inventifs. En compensation, le script IMPRIME ce qu'il écarte : la dérive se
# voit à chaque exécution au lieu de se découvrir après.
#
# AUCUNE VALEUR N'EST IMPRIMÉE. Ni sur la sortie, ni dans un fichier temporaire
# lisible : le rendu ne montre que des NOMS de variables. Ce script est fait
# pour être lancé sous les yeux d'un agent ou collé dans un ticket.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$HERE/lib.sh"

ROOT="$(factory_root)"
STATE="$(conf_get FACTORY_STATE /srv/factory)"
SRC="$ROOT/.env"
DEST="${FACTORY_ENV_PATH:-$STATE/secrets/env}"

[[ -r "$SRC" ]] || { echo "push-env: .env racine introuvable ($SRC)" >&2; exit 3; }

# --- ce qui ne franchit pas la frontiere -------------------------------------
# La liste nominative appartient au CONSOMMATEUR (FACTORY_ENV_DENY dans
# factory.conf) : c'est lui qui sait quels acces operateur vivent dans son .env.
# Le motif garde-fou, lui, est universel : un secret de production ou un sudo
# n'a JAMAIS sa place sur une usine, quel que soit le projet.
read -r -a DENY <<<"$(conf_get FACTORY_ENV_DENY)"
deny_pattern='^(PROD_|.*_SUDO_)'
extra_pattern="$(conf_get FACTORY_ENV_DENY_PATTERN)"

denied() {  # <nom> : vrai si la variable reste sur le poste
  local n="$1" d
  for d in "${DENY[@]:-}"; do [[ "$n" == "$d" ]] && return 0; done
  [[ "$n" =~ $deny_pattern ]] && return 0
  [[ -n "$extra_pattern" && "$n" =~ $extra_pattern ]]
}

# --- ce que l'usine ne peut pas heriter du poste -----------------------------
# GH_APP_KEY est universel : la cle vit sur le volume persistant de l'usine,
# pas la ou le poste range la sienne. Le reste appartient au consommateur :
# tools/factory-hooks/env-overrides (lignes KEY=VALUE) porte les valeurs qui
# sont JUSTES chez vous et FAUSSES sur l'usine (DSN, domaines d'adressage...).
declare -A OVERRIDE=(
  [GH_APP_KEY]="$STATE/secrets/gh-app.pem"
)
if [[ -r "$ROOT/tools/factory-hooks/env-overrides" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in \#*|'') continue ;; esac
    OVERRIDE["${line%%=*}"]="${line#*=}"
  done < "$ROOT/tools/factory-hooks/env-overrides"
fi

# --- ce qui appartient à l'usine et ne vient donc PAS du poste ---------------
# GH_APP_ID / GH_APP_INSTALL_ID identifient l'App installée sur le dépôt : c'est
# l'identité de la MACHINE, pas une préférence de développeur. Un poste ne les
# porte pas (le .env.example les laisse vides), donc les projeter revient à les
# effacer — et une commande censée poser une configuration détruit alors ce
# qu'elle devait compléter. Observé : le premier push-env.sh a vidé l'identité
# de l'usine, et install.sh s'est arrêté sur « GH_APP_ID absent » juste après.
# On va donc les CHERCHER SUR L'USINE et les reporter tels quels.
FACTORY_OWNED=(GH_APP_ID GH_APP_INSTALL_ID)

carried="$(factory_ssh "
  for f in '$DEST'; do
    [ -r \"\$f\" ] || continue
    sed -n \"s/^\(GH_APP_ID\|GH_APP_INSTALL_ID\)=\(..*\)\$/\1=\2/p\" \"\$f\"
  done | awk -F= \"!seen[\\\$1]++\"
")" || { echo "push-env: usine injoignable" >&2; exit 3; }

for k in "${FACTORY_OWNED[@]}"; do
  grep -q "^$k=" <<<"$carried" || {
    echo "push-env: $k introuvable sur l'usine — refus d'écrire un .env qui la priverait de son identité GitHub." >&2
    echo "  posez la valeur dans /srv/factory/secrets/env sur l'usine, puis relancez." >&2
    exit 3
  }
done

# --- composition -------------------------------------------------------------
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
chmod 600 "$tmp"

kept=(); dropped=(); forced=()

{
  echo "# .env de l'usine — PROJECTION du .env racine d'un poste."
  echo "# Composé par tools/factory/push-env.sh. Ne l'éditez pas à la main :"
  echo "# la prochaine exécution écrase le fichier. Corrigez le .env racine."
} >> "$tmp"

while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in \#*|'') continue ;; esac
  key="${line%%=*}"
  case "$key" in *[!A-Za-z0-9_]*|'') continue ;; esac

  if denied "$key"; then dropped+=("$key"); continue; fi
  if [[ -n "${OVERRIDE[$key]+x}" ]]; then continue; fi   # écrites en bloc plus bas
  if [[ " ${FACTORY_OWNED[*]} " == *" $key "* ]]; then continue; fi
  printf '%s\n' "$line" >> "$tmp"
  kept+=("$key")
done < "$SRC"

{
  echo ""
  echo "# --- valeurs propres à l'usine (écrasent le poste) ---"
} >> "$tmp"
for k in "${!OVERRIDE[@]}"; do
  printf '%s=%s\n' "$k" "${OVERRIDE[$k]}" >> "$tmp"
  forced+=("$k")
done
printf '%s\n' "$carried" >> "$tmp"

# --- dépôt sur le volume persistant ------------------------------------------
# Sur le VOLUME, pas dans le dépôt : le dépôt est re-cloné par install.sh et
# emporté par un reset ; le volume traverse les deux. install.sh l'y relie.
factory_ssh "mkdir -p '$(dirname "$DEST")' && cat > '$DEST' && chmod 600 '$DEST'" < "$tmp"

echo "[push-env] $DEST — ${#kept[@]} variables reportées."
printf '  forcées pour l usine : %s\n' "${forced[*]}"
printf '  gardées de l usine   : %s\n' "${FACTORY_OWNED[*]}"
printf '  laissées sur le poste : %s\n' "${dropped[*]:-aucune}"
