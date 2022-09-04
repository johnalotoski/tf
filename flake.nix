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
      in rec {
        packages = rec {
          default = tf-plan;

          # shell cmd or `nix run .#tf-plan`
          tf-plan = pkgs.writeShellApplication {
            name = "tf-plan";
            runtimeInputs = with pkgs; [defaultPackage nix terraform];
            text = ''
              nix build .#terranixConfig --out-link config.tf.json
              terraform plan -out terraform.plan
            '';
          };

          # shell cmd or `nix run .#tf-apply`
          tf-apply = pkgs.writeShellApplication {
            name = "tf-apply";
            runtimeInputs = with pkgs; [terraform];
            text = ''
              terraform apply terraform.plan
            '';
          };

          # shell cmd or `nix run .#tf-deploy`
          tf-deploy = pkgs.writeShellApplication {
            name = "tf-deploy";
            runtimeInputs = with pkgs; [jq terraform];
            text = ''
              IP=$(terraform output --json | jq -r '.ip.value')
              echo "Deploying to $IP"
              nixos-rebuild -v --flake .#spot \
                --build-host "root@$IP" \
                --target-host "root@$IP" \
                --use-substitutes \
                switch
            '';
          };

          # shell cmd or `nix run .#tf-destroy`
          tf-destroy = pkgs.writeShellApplication {
            name = "tf-destroy";
            runtimeInputs = with pkgs; [terraform];
            text = ''
              terraform destroy
            '';
          };

          # nix build .#terranixConfig --out-link config.tf.json
          terranixConfig = terranix.lib.terranixConfiguration {
            inherit system;
            modules = [
              ./config.nix
            ];
          };
        };

        defaultPackage = packages.terranixConfig;

        devShells.default = pkgs.mkShell {
          buildInputs = [
            pkgs.terraform
            pkgs.terranix
            packages.tf-plan
            packages.tf-apply
            packages.tf-deploy
            packages.tf-destroy
          ];
        };

        devShell = devShells.default;
      }) // {
        # IP=<IP> nixos-rebuild --flake .#spot --build-host "root@$IP" --target-host "root@$IP" switch
        nixosConfigurations.spot = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ({ modulesPath, pkgs, config, ... }: {
              imports = [ "${modulesPath}/virtualisation/amazon-image.nix" ];
              ec2.hvm = true;

              nix = {
                binaryCaches = [ "https://cache.iog.io" ];
                binaryCachePublicKeys = [ "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ=" ];
                package = pkgs.nixVersions.nix_2_9;
                settings.experimental-features = [ "nix-command" "flakes" ];
              };

              environment.systemPackages = with pkgs; let
                dbsync-deps-pull = pkgs.writeShellApplication {
                  name = "dbsync-deps-pull";
                  runtimeInputs = [fd gnutar wget];
                  text = ''
                    echo "Enter the cardano-db-sync binary hydra release download url:"
                    read -r DBSYNC
                    echo
                    echo "Enter the latest snapshot release download url:"
                    read -r SNAPSHOT
                    echo
                    mkdir -p /root/dbsync/ledger
                    cd /root/dbsync
                    wget -qN --show-progress "https://raw.githubusercontent.com/input-output-hk/cardano-db-sync/master/scripts/postgresql-setup.sh"
                    echo
                    wget -qN --show-progress "$DBSYNC"
                    echo
                    wget -qN --show-progress "$SNAPSHOT"
                    echo
                    wget -qN --show-progress "$SNAPSHOT.sha256sum"
                    echo
                    sha256sum -c ./*.sha256sum
                    echo
                    fd -t f 'cardano-db-sync-.*.tar.gz' -x tar -zxvf
                    echo
                    chmod +x postgresql-setup.sh
                    echo
                    echo "dbsync-deps-pull successful"
                  '';
                };

                dbsync-restore = pkgs.writeShellApplication {
                  name = "dbsync-restore";
                  runtimeInputs = [fd gnutar];
                  text = ''
                    cd /root/dbsync
                    export PATH=$PATH:/root/dbsync
                    PGPASSFILE=/etc/pgpass postgresql-setup.sh \
                      --restore-snapshot \
                      "$(fd -t f '.tgz$')" \
                      ledger/
                  '';
                };

                dbsync-env = pkgs.writeShellApplication {
                  name = "dbsync-env";
                  runtimeInputs = [nix];
                  text = ''
                    nix develop github:johnalotoski/ada-rewards-parser#devShell.x86_64-linux
                  '';
                };
              in [
                dbsync-deps-pull
                dbsync-env
                dbsync-restore
                fd
                gitFull
                glances
                jq
                ncdu
                ripgrep
                tmux
                vim
                wget
              ];

              services.postgresql = {
                enable = true;
                identMap = ''
                  admin-user root postgres
                  admin-user postgres postgres
                '';
                authentication = ''
                  local all all ident map=admin-user
                '';
                settings = {
                  max_connections = 200;
                  log_statement = "all";
                  logging_collector = "on";
                };
              };

              environment.etc.pgpass = {
                text = "/run/postgresql:5432:cdbsync:postgres:*";
                mode = "0600";
              };

              system.stateVersion = config.system.nixos.release;
            })
          ];
        };
      };
}
