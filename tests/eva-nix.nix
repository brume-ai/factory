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
  tuned = evaluate { services.factory.eva.model = "gpt-7-test"; services.factory.eva.timezone = "UTC"; };
  start = enabled.systemd.services.factory-eva.serviceConfig.ExecStart;
  rules = enabled.systemd.tmpfiles.rules;
  hasRule = motif: builtins.any (r: nixpkgs.lib.hasInfix motif r) rules;
  hasInfix = nixpkgs.lib.hasInfix;
in
assert enabled.services.factory.eva.enable;
assert !(disabled.systemd.services ? factory-eva);
assert !(legacy.systemd.services ? factory-eva);
assert builtins.elem "multi-user.target" enabled.systemd.services.factory-eva.wantedBy;
assert builtins.elem "factory-eva-image.service" enabled.systemd.services.factory-eva.requires;
assert !(builtins.elem "factory-loop.service" enabled.systemd.services.factory-eva.requires);
assert hasInfix "/srv/factory/eva/workspace:/workspace" start;
assert hasInfix "/srv/factory/secrets/eva:/run/eva:ro" start;
assert !(hasInfix "/secrets/env" start);
assert !(hasInfix "codex-home" start);
assert !(hasInfix "docker.sock" start);
assert hasInfix "/srv/custom/eva/home:/opt/data" custom.systemd.services.factory-eva.serviceConfig.ExecStart;
assert builtins.elem "/srv/factory/secrets/eva/github-app.pem" enabled.systemd.services.factory-eva-workspace.unitConfig.ConditionPathExists;

# --- LA V2 (docs/v2-feature.md § 5, tranche EVA) -----------------------------------
# Le fuseau est dans le conteneur : la fenetre 8 h - 21 h du cron est en heure
# locale, et un conteneur en UTC decale la relance du soir.
assert hasInfix "TZ=" start && hasInfix "Europe/Paris" start;
assert hasInfix "TZ=UTC" tuned.systemd.services.factory-eva.serviceConfig.ExecStart;
# Le wrapper `eva` est sur le PATH de la machine : c'est lui que eva-notify.sh
# et l'unite de setup appellent.
assert builtins.any (p: (p.name or "") == "eva") enabled.environment.systemPackages;
# Le modele, ecrit dans config.yaml AVANT la passerelle, surchargeable — par
# eva-config.py (model: est un MAPPING sur la machine), jamais par un sed.
assert hasInfix "eva-config.py" enabled.systemd.services.factory-eva-config.script;
assert hasInfix "gpt-6-astra" enabled.systemd.services.factory-eva-config.script;
assert !(hasInfix "sed" enabled.systemd.services.factory-eva-config.script);
assert hasInfix "gpt-7-test" tuned.systemd.services.factory-eva-config.script;
assert builtins.elem "factory-eva-config.service" enabled.systemd.services.factory-eva.requires;
assert builtins.elem "factory-eva-config.service" enabled.systemd.services.factory-eva.after;
# Le cron de relance : cree apres la passerelle, idempotent par son nom, sans
# agent, script = le job, livre en Slack, aux heures de la regle.
assert builtins.elem "factory-eva.service" enabled.systemd.services.factory-eva-setup.after;
assert builtins.elem "multi-user.target" enabled.systemd.services.factory-eva-setup.wantedBy;
assert hasInfix "cron list" enabled.systemd.services.factory-eva-setup.script;
assert hasInfix "--name factory-relance --no-agent --script eva-relance.sh --deliver slack '0 8,12,16,20 * * *'" enabled.systemd.services.factory-eva-setup.script;
# Un `cron list` en echec n'est pas « absent » : l'unite echoue, pas de doublon.
assert hasInfix "pas de doublon" enabled.systemd.services.factory-eva-setup.script;
# Le clone d'EVA est rafraichi a chaque demarrage, sous-module compris, avec
# SON jeton en en-tete (pas de credential helper dans son conteneur).
assert hasInfix "submodule update --init" enabled.systemd.services.factory-eva-workspace.script;
assert hasInfix "fetch --quiet origin" enabled.systemd.services.factory-eva-workspace.script;
assert hasInfix "extraheader" enabled.systemd.services.factory-eva-workspace.script;
assert hasInfix "gh-app-token.sh" enabled.systemd.services.factory-eva-workspace.script;
assert hasInfix "checkout --quiet --force -B staging origin/staging" enabled.systemd.services.factory-eva-workspace.script;
assert enabled.systemd.services.factory-eva-workspace.serviceConfig.User == "factory";
# L'arbre de la boucle est monte en lecture seule : eva-watch.sh y lit
# loop.halt et loop.file-vide en repli.
assert hasInfix "/srv/factory/workspace/repo:/factory-repo:ro" start;
# Les previews : EVA DEMANDE (requests monté en écriture — le seul montage où
# elle écrit hors de son état) et RELIT (state en lecture seule, l'hôte seul y
# écrit) ; elle ne lance rien, la socket docker n'est toujours pas là.
# Le répertoire ENTIER en écriture (le brouillon de .tmp se renomme dans
# requests/ sur le même montage), et state/ en lecture seule par-dessus.
assert hasInfix "/srv/factory/previews:/previews " start;
assert !(hasInfix "/srv/factory/previews:/previews:ro" start);
assert hasInfix "/srv/factory/previews/state:/previews/state:ro" start;
assert hasInfix "/srv/custom/previews:/previews " custom.systemd.services.factory-eva.serviceConfig.ExecStart;
# Sans les identifiants d'EVA, le timer de pings ne part pas.
assert builtins.elem "/srv/factory/secrets/eva/github-app.env" enabled.systemd.services.factory-eva-notify.unitConfig.ConditionPathExists;
# Le SOUL est RAFRAICHI a chaque demarrage (`C+`), pas seulement pose la
# premiere fois ; les quatre skills et le shim du cron sont provisionnes.
assert hasRule "C+ /srv/factory/eva/home/SOUL.md";
assert hasRule "C+ /srv/factory/eva/home/scripts/eva-relance.sh 0700";
assert hasRule "C+ /srv/factory/eva/home/skills/factory/factory-decision/SKILL.md";
assert hasRule "C+ /srv/factory/eva/home/skills/factory/factory-merge/SKILL.md";
assert hasRule "C+ /srv/factory/eva/home/skills/factory/factory-release/SKILL.md";
assert hasRule "C+ /srv/factory/eva/home/skills/factory/factory-etat/SKILL.md";
assert hasRule "C+ /srv/factory/eva/home/skills/factory/factory-preview/SKILL.md";
assert !(hasRule "C /srv/factory/eva/home/SOUL.md");
# L'allowlist Slack est verifiee AVANT la passerelle : un ExecStartPre qui
# grep SLACK_ALLOWED_USERS non vide dans runtime.env, avec un message qui dit
# quoi poser (ConditionPathExists ne suffit pas : tmpfiles cree le fichier vide).
assert builtins.isList enabled.systemd.services.factory-eva.serviceConfig.ExecStartPre;
assert builtins.any (p: hasInfix "factory-eva-allowlist" p) enabled.systemd.services.factory-eva.serviceConfig.ExecStartPre;
assert hasInfix "SLACK_ALLOWED_USERS" (builtins.readFile (builtins.head (builtins.filter (p: hasInfix "factory-eva-allowlist" p) (map (p: nixpkgs.lib.removePrefix "+" p) enabled.systemd.services.factory-eva.serviceConfig.ExecStartPre))));
assert hasInfix "/srv/factory/secrets/eva/runtime.env" (builtins.readFile (builtins.head (builtins.filter (p: hasInfix "factory-eva-allowlist" p) (map (p: nixpkgs.lib.removePrefix "+" p) enabled.systemd.services.factory-eva.serviceConfig.ExecStartPre))));
# Les pings partent de l'HOTE par un timer, jamais de la boucle (qui tourne
# dans le conteneur factory-loop, sans wrapper `eva`).
assert builtins.elem "timers.target" enabled.systemd.timers.factory-eva-notify.wantedBy;
assert enabled.systemd.timers.factory-eva-notify.timerConfig.OnUnitActiveSec == "2min";
assert enabled.systemd.services.factory-eva-notify.serviceConfig.User == "factory";
assert enabled.systemd.services.factory-eva-notify.environment.FACTORY_ROOT == enabled.services.factory.repoDir;
assert enabled.systemd.services.factory-eva-notify.environment.EVA_GITHUB_DIR == "/srv/factory/secrets/eva";
assert hasInfix "eva-notify.sh" enabled.systemd.services.factory-eva-notify.script;
true
