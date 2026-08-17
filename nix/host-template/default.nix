# Gabarit de machine d'usine : copiez ce dossier dans le depot consommateur,
# remplissez repoUrl et le socle disque, deployez par nixos-anywhere, puis
# deposez les prerequis humains sur ${stateDir}/secrets (gh-app.pem, env via
# bin/push-env.sh, authorized_keys, homes des agents).
{ lib, ... }:
{
  system.stateVersion = "26.05";
  networking.hostName = "factory-template";
  time.timeZone = "Europe/Paris";

  # Socle disque du gabarit : SUFFISANT POUR EVALUER, a remplacer par le
  # partitionnement reel du VPS (disko ou fileSystems explicites).
  boot.loader.grub.device = "/dev/vda";
  fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };

  services.factory = {
    enable = true;
    repoUrl = "https://github.com/CHANGEZ-MOI/CHANGEZ-MOI.git";
  };

  networking.useDHCP = lib.mkDefault true;
  networking.firewall.allowedTCPPorts = [ 22 ];
}
