{
  description = "factory : usine github-loop (module NixOS)";

  inputs = {
    # EPINGLE SUR LA STABLE (lecon srv3 chez Brume) : une toolchain qui bouge
    # sous les pieds des cartes produit des rouges qu'aucun diff n'explique.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs = { self, nixpkgs, ... }: {
    nixosModules.factory = import ./module.nix;

    # Gabarit d'hote : sert de verification d'evaluation (CI) et de point de
    # depart d'une config de VPS consommateur (copier, remplir, deployer par
    # nixos-anywhere).
    nixosConfigurations.template = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ self.nixosModules.factory ./host-template ];
    };
  };
}
