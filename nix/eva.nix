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
  ];
  runArgs = lib.concatMapStringsSep " " (v: "--volume ${lib.escapeShellArg v}") mounts;
  envArgs = "--env HERMES_UID=${toString config.users.users.${factory.user}.uid} --env HERMES_GID=${toString config.users.groups.users.gid} --env TERMINAL_ENV=local --env TERMINAL_CWD=/workspace --env MESSAGING_CWD=/workspace --env-file ${lib.escapeShellArg "${secrets}/runtime.env"}";
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
  };

  config = lib.mkIf (factory.enable && cfg.enable) {
    system.build.factoryEvaContext = context;
    systemd.tmpfiles.rules = [
      "d ${state} 0700 ${factory.user} users -"
      "d ${state}/home 0700 ${factory.user} users -"
      "C ${state}/home/SOUL.md 0600 ${factory.user} users - ${./eva-soul.md}"
      "d ${state}/workspace 0700 ${factory.user} users -"
      "d ${secrets} 0700 ${factory.user} users -"
      "f ${secrets}/runtime.env 0600 ${factory.user} users -"
    ];
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

    systemd.services.factory-eva = {
      description = "Factory: EVA conversational agent (Hermes)";
      wantedBy = [ "multi-user.target" ];
      after = [ "factory-eva-image.service" "factory-eva-workspace.service" ];
      requires = [ "factory-eva-image.service" ];
      wants = [ "factory-eva-workspace.service" ];
      unitConfig.RequiresMountsFor = [ state secrets ];
      serviceConfig = {
        ExecStartPre = "-${docker} rm -f factory-eva";
        ExecStart = "${docker} run --rm --name factory-eva ${runArgs} ${envArgs} ${image} gateway run";
        ExecStop = "${docker} stop --time 30 factory-eva";
        Restart = "on-failure";
        RestartSec = 15;
        TimeoutStartSec = 0;
        TimeoutStopSec = 45;
      };
    };

    systemd.services.factory-eva-workspace = {
      description = "Factory: independent EVA repository";
      after = [ "factory-eva-image.service" ];
      requires = [ "factory-eva-image.service" ];
      unitConfig = {
        RequiresMountsFor = [ state secrets ];
        ConditionPathExists = [ "${secrets}/github-app.env" "${secrets}/github-app.pem" ];
      };
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        if [ ! -d ${lib.escapeShellArg "${state}/workspace/.git"} ]; then
          ${docker} run --rm ${runArgs} ${envArgs} \
            --user ${toString config.users.users.${factory.user}.uid}:${toString config.users.groups.users.gid} \
            --env HOME=/opt/data --entrypoint /opt/factory-eva/gh ${image} \
            repo clone ${lib.escapeShellArg factory.repoUrl} /workspace -- --branch ${lib.escapeShellArg factory.staging}
        fi
      '';
    };
  };
}
