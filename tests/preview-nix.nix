{ nixpkgs }:
# Les previews côté HÔTE (nix/preview.nix) : ce que la boucle et EVA ne peuvent
# pas faire depuis leurs conteneurs — lancer docker — est fait par deux unités
# de l'hôte, sur un registre partagé que tmpfiles crée avant tout.
let
  evaluate = extra: (nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [ ../nix/module.nix ../nix/host-template extra ];
  }).config;
  enabled = evaluate { };
  custom = evaluate { services.factory.stateDir = "/srv/custom"; services.factory.repoDir = "/srv/custom/workspace/site"; };
  off = evaluate { services.factory.enable = nixpkgs.lib.mkForce false; };
  hasInfix = nixpkgs.lib.hasInfix;
  rules = enabled.systemd.tmpfiles.rules;
  hasRule = motif: builtins.any (r: hasInfix motif r) rules;
  reconcile = enabled.systemd.services.factory-preview;
  reap = enabled.systemd.services.factory-preview-reap;
  path = enabled.systemd.paths.factory-preview;
in
# Le registre, 0770 usine, AVANT les montages : requests (la boucle et EVA
# écrivent) et state (l'hôte seul écrit).
assert hasRule "d /srv/factory/previews 0770 factory users";
assert hasRule "d /srv/factory/previews/requests 0770 factory users";
assert hasRule "d /srv/factory/previews/state 0770 factory users";
assert hasRule "d /srv/factory/previews/.tmp 0770 factory users";
# Le path : un changement dans requests déclenche reconcile, jamais autre chose.
assert builtins.elem "multi-user.target" path.wantedBy;
assert path.pathConfig.PathChanged == "/srv/factory/previews/requests";
assert path.pathConfig.Unit == "factory-preview.service";
assert !(path.pathConfig ? MakeDirectory);
assert !(path.pathConfig ? DirectoryNotEmpty);
assert custom.systemd.paths.factory-preview.pathConfig.PathChanged == "/srv/custom/previews/requests";
# reconcile : oneshot, sous l'utilisateur d'usine, dans le dépôt, avec
# FACTORY_ROOT et FACTORY_STATE (conf_get lit l'environnement d'abord), docker
# et git sur le PATH — un `path` systemd EST le PATH.
assert reconcile.serviceConfig.Type == "oneshot";
assert reconcile.serviceConfig.User == "factory";
assert reconcile.serviceConfig.WorkingDirectory == enabled.services.factory.repoDir;
assert reconcile.environment.FACTORY_ROOT == enabled.services.factory.repoDir;
assert reconcile.environment.FACTORY_STATE == "/srv/factory";
assert hasInfix "preview.sh reconcile" reconcile.script;
assert builtins.any (p: hasInfix "docker" (toString p)) reconcile.path;
assert builtins.any (p: hasInfix "git" (toString p)) reconcile.path;
assert builtins.any (p: hasInfix "util-linux" (toString p)) reconcile.path;
# curl et iproute2 : les crochets attendent que l'app réponde et publient sur l'adresse LAN.
assert builtins.any (p: hasInfix "curl" (toString p)) reconcile.path;
assert builtins.any (p: hasInfix "iproute2" (toString p)) reconcile.path;
assert !(reconcile.serviceConfig ? RemainAfterExit);
# Sans le sous-module (dépôt pas encore cloné), l'unité ne part pas.
assert reconcile.unitConfig.ConditionPathExists == "/srv/factory/workspace/repo/tools/factory/bin/preview.sh";
assert custom.systemd.services.factory-preview.unitConfig.ConditionPathExists == "/srv/custom/workspace/site/tools/factory/bin/preview.sh";
assert custom.systemd.services.factory-preview.environment.FACTORY_STATE == "/srv/custom";
# reap : toutes les dix minutes, le même utilisateur, le même environnement —
# et reconcile DERRIÈRE : ce que le path a raté est rattrapé.
assert hasInfix "preview.sh reap" reap.script;
assert hasInfix "preview.sh reconcile" reap.script;
assert builtins.match "(.|\n)*preview.sh reap(.|\n)*preview.sh reconcile(.|\n)*" reap.script != null;
assert !(hasInfix "preview.sh reap" reconcile.script);
assert reap.serviceConfig.User == "factory";
assert reap.environment.FACTORY_STATE == "/srv/factory";
assert builtins.elem "timers.target" enabled.systemd.timers.factory-preview-reap.wantedBy;
assert enabled.systemd.timers.factory-preview-reap.timerConfig.OnUnitActiveSec == "10min";
assert enabled.systemd.timers.factory-preview-reap.timerConfig.Unit == "factory-preview-reap.service";
# Usine désactivée : rien de tout ça.
assert !(off.systemd.services ? factory-preview);
assert !(off.systemd.paths ? factory-preview);
true
