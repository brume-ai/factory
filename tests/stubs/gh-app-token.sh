#!/usr/bin/env bash
# Deux jetons DISTINCTS de celui que t_setup exporte (FACTORY_TOKEN=t0k3n) : la
# boucle doit frapper le sien en tete de tour (le complet), et un second,
# REDUIT, pour l'agent (`--agent`). Le journal dit lequel a ete demande.
printf 'gh-app-token %s\n' "$*" >> "${LOOP_TEST_DIR:?}/token.log"
if [ "${1:-}" = --agent ]; then echo jeton-agent; else echo frappe-ce-tour; fi
