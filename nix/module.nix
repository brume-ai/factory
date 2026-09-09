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
    stateDevice = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "/dev/disk/by-label/factory-state";
      description = ''
        Peripherique portant `stateDir`, monte par le module. `null` si `stateDir`
        vit sur le disque racine, ou si l'hote declare le montage lui-meme.

        PAR ETIQUETTE, JAMAIS PAR /dev/sdX : l'ordre d'enumeration n'est pas
        garanti d'un demarrage a l'autre, et une fstab qui designe le mauvais
        disque empeche la machine de demarrer.
      '';
      example = "/dev/disk/by-label/factory-state";
    };
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

    # LE VOLUME D'ETAT LUI-MEME. Sans ce montage, `stateDir` est un simple
    # repertoire du disque racine : le magasin d'images y atterrit, une remise a
    # zero de la machine emporte le cache, et les secrets deposes a la main ne
    # survivent a rien. Les deux montages lies ci-dessous n'ont alors plus de
    # source persistante — ils lient la racine sur elle-meme, en silence.
    #
    # `nofail` pour qu'un volume absent n'interdise PAS de demarrer : sinon un
    # incident de stockage devient un incident d'acces, et on perd la machine au
    # moment ou il faut justement s'y connecter pour la reparer.
    fileSystems = lib.mkMerge [
      (lib.mkIf (cfg.stateDevice != null) {
        ${cfg.stateDir} = {
          device = cfg.stateDevice;
          fsType = "ext4";
          options = [ "defaults" "nofail" ];
        };
      })
      {
        # LE MAGASIN D'IMAGES PAR MONTAGE LIE, PAS PAR data-root : docker 29 range
        # ses couches dans le magasin de containerd, que data-root ne gouverne pas.
        #
        # `depends` EST OBLIGATOIRE : un bind dont la source n'est pas encore
        # montee lie le repertoire VIDE du dessous. Docker demarre, ne voit aucune
        # image, en reconstruit une de onze gigaoctets — sur le disque racine — et
        # rien ne signale que le volume, monte entre-temps, est ailleurs.
        "/var/lib/docker" = {
          device = "${cfg.stateDir}/docker";
          fsType = "none";
          options = [ "bind" ];
          depends = [ cfg.stateDir ];
        };
        "/var/lib/containerd" = {
          device = "${cfg.stateDir}/containerd";
          fsType = "none";
          options = [ "bind" ];
          depends = [ cfg.stateDir ];
        };
      }
    ];

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

    # `python3` PARCE QUE LES SCRIPTS DE bin/ EN DEPENDENT SUR L'HOTE, pas
    # seulement dans le conteneur : `deploy.sh` frappe son jeton en lancant
    # `bin/gh-app-token.sh`, qui lit la reponse de l'API en python (ligne 71).
    # Ca marche aujourd'hui uniquement parce que les images cloud embarquent
    # python pour cloud-init — une base qui ne le ferait pas donnerait un
    # deploiement qui echoue sur « jeton impossible a frapper ».
    #
    # `nodejs` N'Y EST PLUS, et c'est deliberé. Il n'est utile qu'a la
    # construction de l'image, ou le service `factory-image` le fournit deja par
    # son propre `path`. Dans systemPackages il etait redondant — et il rendait ce
    # module inutilisable sur un hote qui refuse les toolchains de langage sur le
    # systeme, ce qui est une politique repandue et saine : ils appartiennent au
    # devcontainer du projet.
    environment.systemPackages = with pkgs; [ git jq curl openssl python3 gnumake ];

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
      # `bash` PARCE QUE npx LANCE `sh`, et qu'un `path` systemd EST le PATH :
      # rien d'autre ne s'y trouve. Sur une distribution classique le shell est
      # dans le PATH par accident du systeme ; sur NixOS il n'y a pas d'accident,
      # et la CLI Dev Containers s'arrete sur `npm error enoent spawn sh` — un
      # message qui parle de npm et pas du tout du shell manquant.
      path = with pkgs; [ bash nodejs_22 git coreutils config.virtualisation.docker.package ];
      # PAR LA CLI DEV CONTAINERS, jamais docker build : une Feature n'est
      # appliquee que par l'outillage Dev Containers.
      script = sh ''
        npx -y @devcontainers/cli@0.88.0 build \
          --workspace-folder ${cfg.repoDir} --image-name ${cfg.imageTag}

        # GARDE : une image sans CLI Docker franchit toutes les etapes suivantes
        # et ne se revele qu'a la premiere carte. Un `docker compose build` ou une
        # base mal choisie produit exactement ca — la Feature docker-in-docker
        # n'est appliquee que par l'outillage Dev Containers — et la panne se
        # presente alors comme un probleme de carte, tres loin de sa cause.
        # On le verifie pendant qu'on regarde.
        ${docker} run --rm ${cfg.imageTag} bash -lc 'command -v docker >/dev/null' \
          || { echo "l'image batie n'a pas de CLI Docker : la boucle ne pourra pas monter de stack" >&2; exit 1; }
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
      # MEME RAISON QUE POUR factory-image, ET C'EST LA MEME PANNE : un `path`
      # systemd EST le PATH de l'unite. `ExecStart` nomme bash par son chemin
      # absolu, mais le script, lui, appelle `docker` et `env bash` par leur nom.
      # Sans cette ligne : « docker: command not found », « env: 'bash': No such
      # file or directory », sortie 127 — et `Restart = always` en fait une boucle
      # d'echec toutes les trente secondes, qui ressemble a une usine qui redemarre.
      #
      # `git` parce que le script rafraichit le depot avant de lancer un tour.
      # Le reste (coreutils, findutils, gnugrep, gnused) est ajoute par NixOS a
      # toute unite, ce qui explique que seuls docker et bash aient manque.
      path = with pkgs; [ bash git config.virtualisation.docker.package ];
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
