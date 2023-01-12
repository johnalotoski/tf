{
  description = "TF VPN Machine";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-22.11";
    flake-utils.url = "github:numtide/flake-utils";
    terranix.url = "github:terranix/terranix";
    cardano-db-sync.url = "github:input-output-hk/cardano-db-sync/13.0.4";
    cardano-node.url = "github:input-output-hk/cardano-node/1.35.3";
    iohk-nix.url = "github:input-output-hk/iohk-nix";
  };

  outputs = all@{ self, nixpkgs, flake-utils, terranix, cardano-node, iohk-nix, ... }: let
      overlays = [
        iohk-nix.overlays.cardano-lib
      ];
      pkgsForSystem = system:
        import nixpkgs {
          inherit overlays system;
        };
  in flake-utils.lib.eachDefaultSystem (system: let
      pkgs = pkgsForSystem system;
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

          # shell cmd or `nix run .#tf-build`
          tf-build = pkgs.writeShellApplication {
            name = "tf-build";
            runtimeInputs = with pkgs; [jq terraform];
            text = ''
              echo "Building the TF spot machine..."
              nix build -L .#nixosConfigurations.spot.config.system.build.toplevel
            '';
          };

          # TODO: Need to get spongix cache working on first deploy
          # shell cmd or `nix run .#tf-deploy`
          tf-deploy = pkgs.writeShellApplication {
            name = "tf-deploy";
            runtimeInputs = with pkgs; [jq terraform];
            text = ''
              IP=$(terraform output --json | jq -r '.ip.value')
              echo "Deploying to $IP"
              NIX_SSHOPTS="-o StrictHostKeyChecking=accept-new" nixos-rebuild -v --flake .#spot \
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
        nixosConfigurations.spot = nixpkgs.lib.nixosSystem rec {
          system = "x86_64-linux";
          pkgs = pkgsForSystem system;
          modules = [
            ({ modulesPath, pkgs, config, lib, ... }: {
              imports = [
                "${modulesPath}/virtualisation/amazon-image.nix"
                self.inputs.cardano-db-sync.nixosModules.cardano-db-sync
                self.inputs.cardano-node.nixosModules.cardano-node
              ];
              ec2.hvm = true;

              # Don't start the node service immediately so we have a chance to copy state snapshot in
              systemd.services.cardano-node.wantedBy = lib.mkForce [];

              services.cardano-node = {
                enable = true;
                environment = "mainnet";
              };

              services.cardano-db-sync = rec {
                enable = true;
                cluster = "mainnet";
                environment = pkgs.cardanoLib.environments.mainnet;
                explorerConfig = environment.explorerConfig;
                socketPath = config.services.cardano-node.socketPath;
                logConfig = pkgs.cardanoLib.defaultExplorerLogConfig // { PrometheusPort = 12698; };
                postgres = {
                  database = "cexplorer";
                };
              };

              systemd.services.cardano-db-sync = {
                environment = {
                  DISABLE_LEDGER = "";
                  DISABLE_CACHE = "";
                  DISABLE_EPOCH = "";
                };
                serviceConfig = {
                  Restart = "always";
                  RestartSec = "30s";
                };
              };

              nix.settings = {
                substituters = [ "https://cache.iog.io" ];
                trusted-public-keys = [ "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ=" ];
                experimental-features = [ "nix-command" "flakes" ];
              };

              environment.systemPackages = with pkgs; let
                dbsync-deps-pull = pkgs.writeShellApplication {
                  name = "dbsync-deps-pull";
                  runtimeInputs = [fd gnutar wget];
                  text = ''
                    echo "Enter the latest snapshot release download url or <enter> for the last known default snapshot:"
                    read -r SNAPSHOT
                    echo
                    if [ "$SNAPSHOT" = "" ]; then
                      SNAPSHOT="https://update-cardano-mainnet.iohk.io/cardano-db-sync/13/db-sync-snapshot-schema-13-block-8148569-x86_64.tgz"
                    fi
                    mkdir -p /root/dbsync/ledger
                    cd /root/dbsync
                    wget -qN --show-progress "https://raw.githubusercontent.com/input-output-hk/cardano-db-sync/master/scripts/postgresql-setup.sh"
                    echo
                    wget -qN --show-progress "$SNAPSHOT"
                    echo
                    wget -qN --show-progress "$SNAPSHOT.sha256sum"
                    echo
                    sha256sum -c ./*.sha256sum
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
                      /var/lib/cexplorer
                  '';
                };

                dbsync-env = pkgs.writeShellApplication {
                  name = "dbsync-env";
                  runtimeInputs = [nix];
                  text = ''
                    nix develop github:johnalotoski/ada-rewards-parser#devShell.x86_64-linux
                  '';
                };

                node-deps-pull = pkgs.writeShellApplication {
                  name = "node-deps-pull";
                  runtimeInputs = [wget];
                  text = ''
                    echo "Pulling the latest node snapshot"
                    SNAPSHOT="https://update-cardano-mainnet.iohk.io/cardano-node-state/db-mainnet.tar.gz"
                    wget -qN --show-progress "$SNAPSHOT"
                    echo
                    wget -qN --show-progress "$SNAPSHOT.sha256sum"
                    echo
                    sha256sum -c ./*.sha256sum
                    echo
                    echo "node-deps-pull successful"
                  '';
                };

                cardano-cli = self.inputs.cardano-node.packages.x86_64-linux.cardano-cli;
                cardano-db-sync = self.inputs.cardano-db-sync.packages.x86_64-linux."cardano-db-sync:exe:cardano-db-sync";
                cardano-db-tool = self.inputs.cardano-db-sync.packages.x86_64-linux."cardano-db-tool:exe:cardano-db-tool";
              in [
                awscli2
                cardano-cli
                cardano-db-sync
                cardano-db-tool
                dbsync-deps-pull
                dbsync-env
                dbsync-restore
                fd
                gitFull
                glances
                jq
                ncdu
                node-deps-pull
                ripgrep
                tmux
                vim
                wget
              ];

              services.postgresql = {
                enable = true;
                ensureDatabases = [ "cexplorer" ];
                ensureUsers = [
                  {
                    name = "cexplorer";
                    ensurePermissions = {
                      "DATABASE cexplorer" = "ALL PRIVILEGES";
                      "ALL TABLES IN SCHEMA information_schema" = "SELECT";
                      "ALL TABLES IN SCHEMA pg_catalog" = "SELECT";
                    };
                  }
                ];
                identMap = ''
                  explorer-users postgres postgres
                  explorer-users root postgres
                  explorer-users root cexplorer
                  explorer-users cardano-db-sync cexplorer
                '';
                initialScript = builtins.toFile "enable-pgcrypto.sql" ''
                  \connect template1
                  CREATE EXTENSION IF NOT EXISTS pgcrypto SCHEMA pg_catalog;
                '';
                authentication = ''
                  local all all ident map=explorer-users
                '';
                settings = {
                  max_connections = 200;
                  log_statement = "all";
                  logging_collector = "on";
                };
              };

              # Needs to be the same as the cardano-db-sync default pgpass, otherwise,
              # cardano-db-sync startup migrations will fail.

              # cardano-node socket also needs chmod g+w for cardano-db-sync node group access.
              environment.etc.pgpass = {
                text = "/run/postgresql:5432:cexplorer:cexplorer:*";
                mode = "0600";
              };

              system.stateVersion = config.system.nixos.release;
            })
          ];
        };
      };
}
