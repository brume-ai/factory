# Module NixOS de l'usine : docker, depot a jour, image devcontainer, boucle.
# Adapte de Brume (tools/factory/nix/configuration.nix au SHA 12ac9e92), ou
# chaque bloc porte le nom du piege qui l'a rendu necessaire.
#
# CE QU'IL NE COUVRE PAS, deliberement : l'IMAGE du devcontainer (elle reste
# bâtie par la CLI Dev Containers, du meme devcontainer.json que les postes) et
# les services applicatifs du projet (a declarer dans la config d'hote du
# consommateur, comme Brume le fait pour sa stack compose).
{ config, pkgs, lib, ... }:

let
  cfg = config.services.factory;
  secrets = "${cfg.stateDir}/secrets";
  sh = script: "${pkgs.bash}/bin/bash -o pipefail -euc ${lib.escapeShellArg script}";
  docker = "${config.virtualisation.docker.package}/bin/docker";
in
{
  options.services.factory = {
    enable = lib.mkEnableOption "usine github-loop";
    repoUrl = lib.mkOption {
      type = lib.types.str;
      description = "URL https du depot consommateur (clone par jeton d'App).";
      example = "https://github.com/mon-org/mon-depot.git";
    };
    trunk = lib.mkOption { type = lib.types.str; default = "main"; };
    stateDir = lib.mkOption { type = lib.types.str; default = "/srv/factory"; };
    repoDir = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.stateDir}/workspace/repo";
    };
    imageTag = lib.mkOption { type = lib.types.str; default = "factory:dev"; };
    user = lib.mkOption { type = lib.types.str; default = "factory"; };
    buildImage = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Construire l'image devcontainer au demarrage (CLI Dev Containers).";
    };
  };

  config = lib.mkIf cfg.enable {
    # LES REPERTOIRES AVANT LES MONTAGES : un chemin monte par docker run -v qui
    # n'existe pas est cree EN ROOT, et le conteneur (vscode) echoue a y ecrire
    # son jeton APRES le geste humain de login.
    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir}/docker      0710 root        root  -"
      "d ${cfg.stateDir}/containerd  0710 root        root  -"
      "d ${cfg.stateDir}/workspace   0755 ${cfg.user} users -"
      "d ${secrets}                  0700 ${cfg.user} users -"
      "d ${secrets}/claude-home      0700 ${cfg.user} users -"
      "d ${secrets}/codex-home       0700 ${cfg.user} users -"
      "d ${secrets}/gemini-home      0700 ${cfg.user} users -"
      # L'APPROBATION du workspace, que Claude lit hors de ~/.claude.
      "f ${secrets}/claude-home/.claude.json 0600 ${cfg.user} users - {}"
    ];

    # LE MAGASIN D'IMAGES PAR MONTAGE LIE, PAS PAR data-root : docker 29 range
    # ses couches dans le magasin de containerd, que data-root ne gouverne pas.
    fileSystems."/var/lib/docker" = {
      device = "${cfg.stateDir}/docker";
      fsType = "none";
      options = [ "bind" ];
    };
    fileSystems."/var/lib/containerd" = {
      device = "${cfg.stateDir}/containerd";
      fsType = "none";
      options = [ "bind" ];
    };

    users.users.${cfg.user} = {
      isNormalUser = true;
      extraGroups = [ "wheel" "docker" ];
    };
    security.sudo.wheelNeedsPassword = false;

    services.openssh = {
      enable = true;
      settings.PasswordAuthentication = false;
      settings.PermitRootLogin = "no";
      # authorizedKeysFiles et PAS users.*.openssh.authorizedKeys.keyFiles :
      # keyFiles est lu A L'EVALUATION, et un flake s'evalue en mode PUR qui
      # refuse tout chemin hors de son arbre (lecon srv3 chez Brume, 2026-08-06).
      # sshd, lui, lit ce fichier au demarrage.
      authorizedKeysFiles = [ "${secrets}/authorized_keys" ];
    };

    environment.systemPackages = with pkgs; [ git jq curl openssl nodejs_22 gnumake ];

    virtualisation.docker = {
      enable = true;
      autoPrune = {
        enable = true;
        dates = "weekly";
        flags = [ "--all" "--filter" "until=168h" ];
      };
    };

    # Le depot, par jeton d'App frappe inline : le script versionne qui frappe
    # les jetons est DANS le depot, qui n'existe pas encore au premier boot.
    # Si vous corrigez l'un, regardez l'autre (bin/gh-app-token.sh).
    systemd.services.factory-repo = {
      description = "Usine : depot a jour";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = cfg.user;
      };
      path = with pkgs; [ git curl openssl coreutils gnused ];
      script = sh ''
        for f in ${secrets}/gh-app.pem ${secrets}/env; do
          [ -r "$f" ] || { echo "prerequis absent : $f (voir bin/push-env.sh)" >&2; exit 3; }
        done
        app_id=$(sed -n 's/^GH_APP_ID=//p' ${secrets}/env | tail -1)
        install_id=$(sed -n 's/^GH_APP_INSTALL_ID=//p' ${secrets}/env | tail -1)
        [ -n "$app_id" ] && [ -n "$install_id" ] || { echo "GH_APP_ID / GH_APP_INSTALL_ID absents du .env de l'usine" >&2; exit 3; }
        b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
        now=$(date +%s)
        hdr=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
        pay=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now-60)) $((now+540)) "$app_id" | b64url)
        sig=$(printf '%s.%s' "$hdr" "$pay" | openssl dgst -sha256 -sign ${secrets}/gh-app.pem -binary | b64url)
        token=$(curl -sS -X POST -H "Authorization: Bearer $hdr.$pay.$sig" \
          -H "Accept: application/vnd.github+json" \
          "https://api.github.com/app/installations/$install_id/access_tokens" \
          | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        [ -n "$token" ] || { echo "jeton d'installation impossible a frapper" >&2; exit 3; }
        auth="Authorization: Basic $(printf 'x-access-token:%s' "$token" | base64 -w0)"
        mkdir -p "$(dirname ${cfg.repoDir})"
        if [ -d ${cfg.repoDir}/.git ]; then
          git -c "http.https://github.com/.extraheader=$auth" -C ${cfg.repoDir} fetch --quiet origin
          git -C ${cfg.repoDir} reset --hard --quiet origin/${cfg.trunk}
        else
          git -c "http.https://github.com/.extraheader=$auth" clone --quiet ${cfg.repoUrl} ${cfg.repoDir}
        fi
        git -c "http.https://github.com/.extraheader=$auth" -C ${cfg.repoDir} \
          submodule update --init --quiet
        ln -sfn ${secrets}/env ${cfg.repoDir}/.env
      '';
    };

    systemd.services.factory-image = lib.mkIf cfg.buildImage {
      description = "Usine : image du devcontainer (Features comprises)";
      after = [ "factory-repo.service" "docker.service" ];
      requires = [ "factory-repo.service" "docker.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = cfg.user;
        WorkingDirectory = cfg.repoDir;
      };
      path = with pkgs; [ nodejs_22 git coreutils config.virtualisation.docker.package ];
      # PAR LA CLI DEV CONTAINERS, jamais docker build : une Feature n'est
      # appliquee que par l'outillage Dev Containers.
      script = sh ''
        npx -y @devcontainers/cli@0.88.0 build \
          --workspace-folder ${cfg.repoDir} --image-name ${cfg.imageTag}
      '';
    };

    systemd.services.factory-loop = {
      description = "Usine : boucle github-loop";
      after = [ (if cfg.buildImage then "factory-image.service" else "factory-repo.service") ];
      requires = [ (if cfg.buildImage then "factory-image.service" else "factory-repo.service") ];
      wantedBy = [ "multi-user.target" ];
      # LES OPTIONS DU MODULE DOIVENT PARVENIR AUX SCRIPTS, sinon deux verites
      # divergent (defaut nix workspace/repo vs defaut shell workspace/<nom du
      # depot>). conf_get lit l'environnement AVANT tout fichier, donc ces
      # valeurs deviennent autoritaires pour run-loop.sh comme pour le reste.
      environment = {
        FACTORY_ROOT = cfg.repoDir;
        FACTORY_REPO_DIR = cfg.repoDir;
        FACTORY_STATE = cfg.stateDir;
        FACTORY_IMAGE_TAG = cfg.imageTag;
        FACTORY_TRUNK = cfg.trunk;
      };
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        WorkingDirectory = cfg.repoDir;
        ExecStart = "${pkgs.bash}/bin/bash ${cfg.repoDir}/tools/factory/bin/run-loop.sh";
        # systemd envoie SIGTERM au processus docker, qui ne l'achemine pas au
        # conteneur : on coupe nommement, et 137 est l'arret NORMAL.
        ExecStop = "${docker} rm -f factory-loop";
        SuccessExitStatus = 137;
        TimeoutStopSec = 60;
        Restart = "always";
        RestartSec = 30;
      };
    };
  };
}
