{ nixpkgs }:
let
  evaluate = extra: (nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [ ../nix/module.nix ../nix/host-template extra ];
  }).config;
  enabled = evaluate { };
  disabled = evaluate { services.factory.eva.enable = false; };
  custom = evaluate { services.factory.stateDir = "/srv/custom"; };
  legacy = evaluate { virtualisation.oci-containers.containers.hermes.image = "hermes:existing"; };
  start = enabled.systemd.services.factory-eva.serviceConfig.ExecStart;
in
assert enabled.services.factory.eva.enable;
assert !(disabled.systemd.services ? factory-eva);
assert !(legacy.systemd.services ? factory-eva);
assert builtins.elem "multi-user.target" enabled.systemd.services.factory-eva.wantedBy;
assert builtins.elem "factory-eva-image.service" enabled.systemd.services.factory-eva.requires;
assert !(builtins.elem "factory-loop.service" enabled.systemd.services.factory-eva.requires);
assert nixpkgs.lib.hasInfix "/srv/factory/eva/workspace:/workspace" start;
assert nixpkgs.lib.hasInfix "/srv/factory/secrets/eva:/run/eva:ro" start;
assert !(nixpkgs.lib.hasInfix "/secrets/env" start);
assert !(nixpkgs.lib.hasInfix "codex-home" start);
assert !(nixpkgs.lib.hasInfix "docker.sock" start);
assert nixpkgs.lib.hasInfix "/srv/custom/eva/home:/opt/data" custom.systemd.services.factory-eva.serviceConfig.ExecStart;
assert builtins.elem "/srv/factory/secrets/eva/github-app.pem" enabled.systemd.services.factory-eva-workspace.unitConfig.ConditionPathExists;
true
