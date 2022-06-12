{
  description = "TF VPN Machine";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-22.05";
    flake-utils.url = "github:numtide/flake-utils";
    terranix.url = "github:terranix/terranix";
  };

  outputs = all@{ self, nixpkgs, flake-utils, terranix, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in {
        defaultPackage = terranix.lib.terranixConfiguration {
          inherit system;
          modules = [
            ./config.nix
          ];
        };
        devShells.default = pkgs.mkShell {
          buildInputs = [
            pkgs.terraform
            pkgs.terranix
          ];
        };
      }
    );
}
