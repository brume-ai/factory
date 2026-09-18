# Les previews par PR, côté HÔTE (docs/release.md « Les previews »).
#
# LE FAIT QUI DONNE SA FORME À CE FICHIER : la boucle tourne dans le conteneur
# factory-loop et EVA dans factory-eva ; ni l'une ni l'autre ne lance `docker`
# ou `systemctl`. Elles DÉPOSENT une demande dans ${stateDir}/previews/requests
# (bin/preview.sh request) ; c'est l'hôte qui agit, par deux unités :
#   - factory-preview.path → factory-preview.service : `preview.sh reconcile`
#     à chaque changement du répertoire des demandes (PathChanged : un fichier
#     créé, remplacé — les demandes sont écrites par renommage — ou effacé) ;
#     il monte, remonte ou éteint par les crochets preview-up / preview-down
#     du dépôt consommateur, et écrit l'état ;
#   - factory-preview-reap.timer, toutes les dix minutes : `preview.sh reap`
#     (éteint ce qui a expiré — FACTORY_PREVIEW_TTL —, dont le worktree a
#     disparu — wt-cleanup.sh l'a retiré, la PR est mergée ou fermée —, ou en
#     erreur) PUIS `preview.sh reconcile` : ce que le path a raté — une demande
#     déposée avant le démarrage, ou arrivée pendant qu'une unité tournait,
#     que l'inotify de systemd ne rejoue pas — est rattrapé sous dix minutes.
#     Pas de DirectoryNotEmpty : il tirerait en boucle sur une demande que
#     reconcile refuse de traiter (un nom qui n'est pas un numéro).
# Sous l'utilisateur d'usine : les worktrees lui appartiennent, il est dans
# le groupe docker, et un conteneur lancé par root monterait des chemins que le
# crochet ne pourrait plus nettoyer. `docker` est sur le PATH de l'unité — un
# `path` systemd EST le PATH, la panne exacte de factory-loop (nix/module.nix).
#
# Les deux répertoires existent AVANT tout (tmpfiles, 0770 usine) : un montage
# docker sur un chemin absent le créerait en root, et ni la boucle (vscode,
# uid 1000) ni EVA n'y écriraient plus. Le conteneur d'EVA les monte
# (nix/eva.nix) : requests en écriture, state en lecture.
{ config, pkgs, lib, ... }:
let
  cfg = config.services.factory;
  previews = "${cfg.stateDir}/previews";
  unite = script: {
    serviceConfig = {
      Type = "oneshot";
      User = cfg.user;
      WorkingDirectory = cfg.repoDir;
    };
    # Sans le sous-module (premier démarrage, dépôt pas encore cloné), il n'y
    # a rien à lancer : l'unité ne part pas plutôt que d'échouer.
    unitConfig.ConditionPathExists = "${cfg.repoDir}/tools/factory/bin/preview.sh";
    environment = {
      FACTORY_ROOT = cfg.repoDir;
      FACTORY_STATE = cfg.stateDir;
    };
    # curl et iproute2 pour les CROCHETS du consommateur : attendre que
    # l'application réponde, trouver l'adresse LAN sur laquelle publier.
    path = with pkgs; [ bash git coreutils gnused gnugrep python3 util-linux curl iproute2 config.virtualisation.docker.package ];
    inherit script;
  };
in
{
  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d ${previews} 0770 ${cfg.user} users -"
      "d ${previews}/requests 0770 ${cfg.user} users -"
      "d ${previews}/state 0770 ${cfg.user} users -"
      # Les brouillons des écritures, renommés en place — hors de requests/,
      # que le path surveille.
      "d ${previews}/.tmp 0770 ${cfg.user} users -"
    ];

    systemd.paths.factory-preview = {
      description = "Usine : demandes de preview (déclenche factory-preview)";
      wantedBy = [ "multi-user.target" ];
      unitConfig.RequiresMountsFor = [ cfg.stateDir ];
      pathConfig = {
        # Le répertoire est créé par tmpfiles (ci-dessus), jamais par le path
        # (`MakeDirectory` le créerait en root, et plus personne n'y écrirait) ;
        # absent, systemd surveille son parent et s'accroche dès qu'il naît.
        PathChanged = "${previews}/requests";
        Unit = "factory-preview.service";
      };
    };
    systemd.services.factory-preview = (unite "exec bash tools/factory/bin/preview.sh reconcile") // {
      description = "Usine : previews — monter, remonter, éteindre sur demande";
    };

    systemd.services.factory-preview-reap = (unite ''
      rc=0
      bash tools/factory/bin/preview.sh reap || rc=$?
      bash tools/factory/bin/preview.sh reconcile || rc=$?
      exit "$rc"
    '') // {
      description = "Usine : previews — éteindre les expirées et les orphelines";
    };
    systemd.timers.factory-preview-reap = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "10min"; OnUnitActiveSec = "10min"; Unit = "factory-preview-reap.service"; };
    };
  };
}
