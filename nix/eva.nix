{ config, pkgs, lib, ... }:
let
  factory = config.services.factory;
  cfg = factory.eva;
  state = "${factory.stateDir}/eva";
  secrets = "${factory.stateDir}/secrets/eva";
  docker = "${config.virtualisation.docker.package}/bin/docker";
  context = pkgs.runCommand "factory-eva-context" { } ''
    mkdir -p "$out"
    cp ${../bin/eva-gh.sh} "$out/gh"
    cp ${../bin/gh-app-token.sh} "$out/gh-app-token.sh"
    cp ${../bin/lib.sh} "$out/lib.sh"
    cat > "$out/Dockerfile" <<'DOCKERFILE'
    FROM ${cfg.image}
    USER root
    RUN apt-get update && apt-get install -y --no-install-recommends gh && rm -rf /var/lib/apt/lists/*
    COPY gh gh-app-token.sh lib.sh /opt/factory-eva/
    RUN chmod 755 /opt/factory-eva/gh && ln -s /opt/factory-eva/gh /usr/local/bin/gh
    DOCKERFILE
  '';
  image = "factory-eva:local";
  mounts = [
    "${state}/home:/opt/data"
    "${state}/workspace:/workspace"
    "${secrets}:/run/eva:ro"
    # L'ARBRE DE LA BOUCLE, EN LECTURE SEULE : c'est là que la boucle écrit
    # `.omc/loop.halt` et `.omc/loop.file-vide`. Depuis son conteneur, EVA n'a
    # que son clone (/workspace), où la boucle n'écrit jamais ; eva-watch.sh
    # lit /factory-repo/.omc en repli (docs/configuration.md).
    "${factory.repoDir}:/factory-repo:ro"
  ];
  runArgs = lib.concatMapStringsSep " " (v: "--volume ${lib.escapeShellArg v}") mounts;
  # TZ DANS LE CONTENEUR, PAS SEULEMENT SUR L'HOTE : le cron d'Hermes lit son
  # horloge dans le conteneur, et « jamais avant 8 h ni apres 21 h » est une
  # regle en heure de Paris (docs/v2-feature.md § 5). Sans cette variable le
  # conteneur est en UTC et la relance de 20 h tombe a 22 h l'ete.
  envArgs = "--env HERMES_UID=${toString config.users.users.${factory.user}.uid} --env HERMES_GID=${toString config.users.groups.users.gid} --env TERMINAL_ENV=local --env TERMINAL_CWD=/workspace --env MESSAGING_CWD=/workspace --env TZ=${lib.escapeShellArg cfg.timezone} --env-file ${lib.escapeShellArg "${secrets}/runtime.env"}";
  # LES SKILLS D'EVA, provisionnes comme SOUL.md : un repertoire par skill sous
  # ~/.hermes/skills/factory/ (~/.hermes = /opt/data = ${state}/home). La liste
  # est celle de skill/eva/ dans ce depot ; un skill absent d'ici n'est pas
  # provisionne, donc pas lu.
  skills = [ "factory-decision" "factory-merge" "factory-release" "factory-etat" ];
  # LE SCRIPT DU CRON EST UN SHIM. Hermes lance `--script <nom>` depuis
  # ~/.hermes/scripts/ ; la relance elle-meme vit dans le depot (bin/eva-relance.sh,
  # qui a besoin de lib.sh a cote de lui) et se lance depuis le clone d'EVA :
  # une copie ici divergerait a la premiere mise a jour du sous-module.
  relanceShim = pkgs.writeText "eva-relance.sh" ''
    #!/usr/bin/env bash
    # Provisionne par nix/eva.nix : la relance vit dans le depot, pas ici.
    cd /workspace && exec bash tools/factory/bin/eva-relance.sh
  '';
  eva = pkgs.writeShellScriptBin "eva" ''
    set -euo pipefail
    args=()
    if [ -t 0 ]; then args+=(-it); fi
    if ${docker} inspect --format '{{.State.Running}}' factory-eva 2>/dev/null | ${pkgs.gnugrep}/bin/grep -qx true; then
      exec ${docker} exec "''${args[@]}" --user ${toString config.users.users.${factory.user}.uid}:${toString config.users.groups.users.gid} --env HOME=/opt/data factory-eva hermes "$@"
    fi
    exec ${docker} run --rm "''${args[@]}" ${runArgs} ${envArgs} ${image} "$@"
  '';
in
{
  options.services.factory.eva = {
    enable = lib.mkOption {
      type = lib.types.bool;
      # Existing consumers may still declare their original Hermes container.
      default = !(config.virtualisation.oci-containers.containers ? hermes);
      description = "Install EVA (Hermes) alongside Pony, with independent persistent state and credentials.";
    };
    image = lib.mkOption {
      type = lib.types.str;
      default = "nousresearch/hermes-agent:v2026.9.14@sha256:99641e57ec762c59e54cb44aa6746b7fc68c18b3c5ddb088af54234c613d9294";
      description = "Pinned upstream Hermes container, extended with the GitHub CLI.";
    };
    model = lib.mkOption {
      type = lib.types.str;
      default = "gpt-6-astra";
      description = ''
        Modele d'EVA, ecrit dans la cle `model` de son config.yaml
        (~/.hermes/config.yaml) par l'unite factory-eva-config avant chaque
        demarrage de la passerelle. Une autre famille que l'orchestrateur de
        la boucle, a dessein (docs/v2-feature.md § 5).
      '';
    };
    timezone = lib.mkOption {
      type = lib.types.str;
      default = "Europe/Paris";
      description = "Fuseau du conteneur d'EVA (TZ) : la fenetre de relance 8 h - 21 h est en heure locale.";
    };
  };

  config = lib.mkIf (factory.enable && cfg.enable) {
    system.build.factoryEvaContext = context;
    systemd.tmpfiles.rules = [
      "d ${state} 0700 ${factory.user} users -"
      "d ${state}/home 0700 ${factory.user} users -"
      # `C+` ET PAS `C` : `C` ne copie que si la destination n'existe pas, donc
      # un SOUL.md reecrit dans le depot ne remplacait jamais celui de la
      # machine — EVA gardait ses anciennes regles apres chaque deploiement.
      # `+` recopie a chaque demarrage ; ces fichiers sont a nous, pas a EVA.
      "C+ ${state}/home/SOUL.md 0600 ${factory.user} users - ${./eva-soul.md}"
      "d ${state}/home/skills 0700 ${factory.user} users -"
      "d ${state}/home/skills/factory 0700 ${factory.user} users -"
      "d ${state}/home/scripts 0700 ${factory.user} users -"
      "C+ ${state}/home/scripts/eva-relance.sh 0700 ${factory.user} users - ${relanceShim}"
      "d ${state}/workspace 0700 ${factory.user} users -"
      "d ${secrets} 0700 ${factory.user} users -"
      "f ${secrets}/runtime.env 0600 ${factory.user} users -"
    ] ++ lib.concatMap (n: [
      "d ${state}/home/skills/factory/${n} 0700 ${factory.user} users -"
      "C+ ${state}/home/skills/factory/${n}/SKILL.md 0600 ${factory.user} users - ${../skill/eva + "/${n}/SKILL.md"}"
    ]) skills;
    environment.systemPackages = [ eva ];

    systemd.services.factory-eva-image = {
      description = "Factory: EVA Hermes runtime";
      after = [ "docker.service" "network-online.target" ];
      requires = [ "docker.service" ];
      wants = [ "network-online.target" ];
      unitConfig.RequiresMountsFor = [ factory.stateDir ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; TimeoutStartSec = "30min"; };
      script = "${docker} build --tag ${image} ${context}";
    };

    # LE MODELE, ECRIT DANS config.yaml AVANT LA PASSERELLE. Hermes lit sa
    # configuration au demarrage de `gateway run` ; la poser apres, par `docker
    # exec`, demanderait un redemarrage que rien ne ferait. L'unite tourne sous
    # l'utilisateur d'usine (le fichier lui appartient, une ecriture en root le
    # lui volerait) et ne touche QUE la cle `model` — par nix/eva-config.py,
    # pas par un `sed` : sur la machine, `model:` est un MAPPING (des lignes
    # indentees dessous), et un sed sur la ligne laissait un YAML invalide. Le
    # reste du fichier est a EVA (jetons, canaux) et sort tel quel.
    # A VERIFIER SUR LA MACHINE a la premiere mise en service : que la cle du
    # mapping que le script pose (`default`) est bien celle que `hermes model`
    # ecrit — sinon adapter eva-config.py, le test le couvre.
    systemd.services.factory-eva-config = {
      description = "Factory: EVA model in config.yaml";
      unitConfig.RequiresMountsFor = [ state ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; User = factory.user; };
      path = with pkgs; [ coreutils python3 ];
      script = ''
        python3 ${./eva-config.py} ${lib.escapeShellArg "${state}/home/config.yaml"} ${lib.escapeShellArg cfg.model}
      '';
    };

    systemd.services.factory-eva = {
      description = "Factory: EVA conversational agent (Hermes)";
      wantedBy = [ "multi-user.target" ];
      after = [ "factory-eva-image.service" "factory-eva-workspace.service" "factory-eva-config.service" ];
      requires = [ "factory-eva-image.service" "factory-eva-config.service" ];
      wants = [ "factory-eva-workspace.service" ];
      unitConfig.RequiresMountsFor = [ state secrets ];
      # L'ALLOWLIST SLACK EST LA SEULE SERRURE SUR QUI ORDONNE A EVA (merger,
      # sortir une version) : sans elle, ou vide, la passerelle prendrait le mot
      # de n'importe qui pour un ordre. Elle n'est provisionnee par rien — c'est
      # un geste humain dans runtime.env, IDs Slack separes par des virgules
      # (voir la doc Hermes) — donc elle est VERIFIEE avant de lancer la
      # passerelle, avec un message qui dit quoi poser. `ConditionPathExists`
      # ne suffit pas : le fichier existe (tmpfiles le cree vide).
      path = with pkgs; [ coreutils gnugrep ];
      serviceConfig = {
        ExecStartPre = [
          ("+" + toString (pkgs.writeShellScript "factory-eva-allowlist" ''
            f=${lib.escapeShellArg "${secrets}/runtime.env"}
            if ! grep -Eq '^[[:space:]]*SLACK_ALLOWED_USERS[[:space:]]*=[[:space:]]*[^[:space:]]' "$f" 2>/dev/null; then
              echo "factory-eva : SLACK_ALLOWED_USERS absent ou vide dans $f — sans allowlist, n'importe qui commanderait EVA (merge, release). Posez-y les IDs Slack autorises, separes par des virgules (voir la doc Hermes), puis relancez." >&2
              exit 1
            fi
          ''))
          "-${docker} rm -f factory-eva"
        ];
        ExecStart = "${docker} run --rm --name factory-eva ${runArgs} ${envArgs} ${image} gateway run";
        ExecStop = "${docker} stop --time 30 factory-eva";
        Restart = "on-failure";
        RestartSec = 15;
        TimeoutStartSec = 0;
        TimeoutStopSec = 45;
      };
    };

    # LE JOB CRON DE RELANCE, CREE UNE FOIS, IDEMPOTEMMENT. `hermes cron` vit
    # dans le conteneur (~/.hermes/cron), donc apres son demarrage, par le
    # wrapper `eva` (docker exec). `--no-agent --script` : le script EST le job,
    # son stdout est livre tel quel en Slack, vide = silence (Hermes 0.21.3,
    # verifie le 18 septembre 2026). Le nom `factory-relance` est ce que `cron
    # list` relit pour ne pas creer un doublon a chaque demarrage. Le conteneur
    # met quelques secondes a repondre a `docker exec` : on attend, borne.
    # UN `cron list` EN ECHEC N'EST PAS « ABSENT » : en creer un sur cette foi
    # ferait un doublon a chaque demarrage ou le conteneur repond mal. L'unite
    # echoue, et le prochain demarrage reessaie.
    systemd.services.factory-eva-setup = {
      description = "Factory: EVA cron jobs";
      wantedBy = [ "multi-user.target" ];
      after = [ "factory-eva.service" ];
      requires = [ "factory-eva.service" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      path = with pkgs; [ coreutils gnugrep config.virtualisation.docker.package ];
      script = ''
        for i in $(seq 1 30); do
          ${docker} inspect --format '{{.State.Running}}' factory-eva 2>/dev/null | grep -qx true && break
          sleep 2
        done
        if ! liste="$(${eva}/bin/eva cron list)"; then
          echo "factory-eva-setup : \`hermes cron list\` a echoue — on ne cree rien sur un etat qu'on n'a pas lu (pas de doublon)" >&2
          exit 1
        fi
        if printf '%s\n' "$liste" | grep -q 'factory-relance'; then
          echo "factory-eva-setup : le job factory-relance existe deja"
        else
          ${eva}/bin/eva cron create --name factory-relance --no-agent --script eva-relance.sh --deliver slack '0 8,12,16,20 * * *'
        fi
      '';
    };

    # LES PINGS PARTENT DE L'HÔTE, PAS DE LA BOUCLE. `make loop` tourne dans le
    # conteneur factory-loop (run-loop.sh), où le wrapper `eva` n'existe pas :
    # un appel depuis la recette dirait « introuvable » une fois et l'usine
    # tournerait sans prévenir personne — la panne exacte du 17 septembre.
    # Un timer hôte lance eva-notify.sh toutes les deux minutes, sous
    # l'utilisateur de l'usine, avec le jeton d'EVA (eva-token.sh lit
    # EVA_GITHUB_DIR) et FACTORY_ROOT sur le dépôt consommateur, dont il lit
    # `.omc/loop.halt` et `.omc/loop.file-vide` sur le volume partagé.
    # eva-notify.sh rend toujours 0 : un raté ne fait pas rougir le timer, il
    # est dans le journal.
    systemd.services.factory-eva-notify = {
      description = "Factory: EVA pings (what awaits a human)";
      after = [ "factory-eva.service" ];
      # Sans les identifiants d'EVA, le ping n'a pas de jeton : l'unite ne
      # part pas, plutot que d'echouer toutes les deux minutes dans le journal.
      unitConfig.ConditionPathExists = [ "${factory.repoDir}/tools/factory/bin/eva-notify.sh" "${secrets}/github-app.env" ];
      serviceConfig = {
        Type = "oneshot";
        User = factory.user;
        WorkingDirectory = factory.repoDir;
      };
      environment = {
        FACTORY_ROOT = factory.repoDir;
        FACTORY_STATE = factory.stateDir;
        EVA_GITHUB_DIR = secrets;
        FACTORY_EVA_SEND = "${eva}/bin/eva";
      };
      path = with pkgs; [ bash coreutils gnugrep gnused curl openssl python3 git config.virtualisation.docker.package ];
      script = ''
        exec bash tools/factory/bin/eva-notify.sh
      '';
    };
    systemd.timers.factory-eva-notify = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "3min"; OnUnitActiveSec = "2min"; Unit = "factory-eva-notify.service"; };
    };

    # LE CLONE D'EVA, A JOUR A CHAQUE DEMARRAGE, SOUS-MODULE COMPRIS. La
    # premiere version clonait une fois, sans `tools/factory/` (pas de
    # --recurse-submodules) et ne rafraichissait jamais : le shim du cron, les
    # skills et eva-release.sh pointaient sur un repertoire vide ou fige. Meme
    # geste que factory-repo (nix/module.nix) pour Pony, avec LE JETON D'EVA :
    # frappe par le gh-app-token.sh du contexte de l'image, passe en en-tete
    # (`extraheader`) — il n'y a pas de credential helper, et le depot est prive.
    # Sur l'hote, sous l'utilisateur d'usine (l'arbre lui appartient).
    systemd.services.factory-eva-workspace = {
      description = "Factory: independent EVA repository";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      unitConfig = {
        RequiresMountsFor = [ state secrets ];
        ConditionPathExists = [ "${secrets}/github-app.env" "${secrets}/github-app.pem" ];
      };
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; User = factory.user; };
      path = with pkgs; [ bash git curl openssl python3 coreutils gnused ];
      script = ''
        set -a; . ${lib.escapeShellArg "${secrets}/github-app.env"}; set +a
        export GH_APP_KEY=${lib.escapeShellArg "${secrets}/github-app.pem"} FACTORY_ROOT=${context}
        token="$(bash ${context}/gh-app-token.sh)"
        auth="Authorization: Basic $(printf 'x-access-token:%s' "$token" | base64 -w0)"
        ws=${lib.escapeShellArg "${state}/workspace"}
        if [ -d "$ws/.git" ]; then
          git -c "http.https://github.com/.extraheader=$auth" -C "$ws" fetch --quiet origin
          git -C "$ws" checkout --quiet --force -B ${lib.escapeShellArg factory.staging} origin/${lib.escapeShellArg factory.staging}
        else
          git -c "http.https://github.com/.extraheader=$auth" clone --quiet --branch ${lib.escapeShellArg factory.staging} ${lib.escapeShellArg factory.repoUrl} "$ws"
        fi
        git -c "http.https://github.com/.extraheader=$auth" -C "$ws" submodule update --init --quiet
      '';
    };
  };
}
