{
  description = "xyne-spaces logical replica sync";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          spacesLaunch = import (builtins.path { path = ./nix/spacesLaunch.nix; name = "spacesLaunch.nix"; });
          metricsStart = import ./nix/grafana.nix { inherit pkgs; };
          syncPodmanStart = import ./nix/syncPodman.nix { inherit pkgs; };
          spacesStart = pkgs.writeShellApplication {
            name = "spaces-start";
            runtimeInputs = [ pkgs.nix pkgs.podman pkgs.util-linux ];
            text = ''
              root=$(git rev-parse --show-toplevel)
              spaces="''${XYNE_SPACES_ROOT:-$root/../xyne-spaces}"
              mkdir -p "$root/.state"
              ${spacesLaunch}
            '';
          };
          syncStart = pkgs.writeShellApplication {
            name = "sync-start";
            runtimeInputs = [ metricsStart syncPodmanStart pkgs.cargo pkgs.coreutils pkgs.git pkgs.gnugrep pkgs.nix pkgs.podman pkgs.postgresql pkgs.rustc pkgs.stdenv.cc pkgs.util-linux ];
            text = ''
              root=$(git rev-parse --show-toplevel)
              primary='postgresql://xyne:xyne123@127.0.0.1:5433/xyne_dev_db'
              pods="''${1:-1}"
              case "$pods" in *[!0-9]*|0) printf 'pods must be a positive integer\n' >&2; exit 2;; esac

              log() {
                printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"
              }

              status() {
                log 'primary status'
                psql "$primary" -c "SELECT current_setting('wal_level') AS wal_level, pg_is_in_recovery() AS in_recovery"
                psql "$primary" -c "SELECT pubname FROM pg_publication WHERE pubname = 'xyne_sync_pub'"
                psql "$primary" -c "SELECT slot_name, active FROM pg_replication_slots WHERE slot_name LIKE 'xyne_sync_slot_%'"
              }

              setup() {
                log 'waiting for xyne-spaces PostgreSQL on 5433'
                until pg_isready -h 127.0.0.1 -p 5433 -U xyne -d xyne_dev_db >/dev/null; do sleep 1; done
                log 'waiting for the primary schema'
                until psql "$primary" -Atqc "SELECT count(*) > 0 FROM pg_tables WHERE schemaname = 'public'" 2>/dev/null | grep -qx t; do sleep 1; done
                log 'checking logical decoding'
                until test "$(psql "$primary" -Atqc 'SHOW wal_level' 2>/dev/null)" = logical; do sleep 1; done
                log 'configuring the primary publication'
                psql "$primary" -v ON_ERROR_STOP=1 -c 'CREATE SCHEMA IF NOT EXISTS zero_0'
                psql "$primary" -v ON_ERROR_STOP=1 -c 'CREATE PUBLICATION xyne_sync_pub FOR TABLES IN SCHEMA public, zero_0' 2>/dev/null || psql "$primary" -v ON_ERROR_STOP=1 -c 'ALTER PUBLICATION xyne_sync_pub SET TABLES IN SCHEMA public, zero_0'
                psql "$primary" -v ON_ERROR_STOP=1 -f "$root/../xyne-sync-ref/scripts/sql/zero-ddl-triggers.sql"
                status
              }

              mkdir -p "$root/.state"
              metrics-start "$pods" &
              metrics_pid=$!
              proxy_pid=""
              cleanup() {
                kill "$metrics_pid" 2>/dev/null || true
                test -z "$proxy_pid" || kill "$proxy_pid" 2>/dev/null || true
              }
              trap cleanup EXIT INT TERM
              setup 2>&1 | tee "$root/.state/sync.log"
              sync-podman-start "$pods" &
              proxy_pid=$!
              wait "$proxy_pid"
            '';
          };
          start = pkgs.writeShellApplication {
            name = "start";
            runtimeInputs = [ spacesStart syncStart ];
            text = ''
              spaces-start &
              sync-start &
              wait
            '';
          };
        in {
          default = start;
          inherit start spacesStart syncStart;
          metricsStart = metricsStart;
          syncPodmanStart = syncPodmanStart;
        });

      apps = forAllSystems (system: {
        start = {
          type = "app";
          program = "${self.packages.${system}.start}/bin/start";
        };
      });

      devShells = forAllSystems (system:
        let pkgs = import nixpkgs { inherit system; };
        in {
          default = pkgs.mkShell {
            packages = [ pkgs.git pkgs.just pkgs.nginx pkgs.podman pkgs.podman-compose pkgs.postgresql self.packages.${system}.start self.packages.${system}.spacesStart self.packages.${system}.syncStart self.packages.${system}.metricsStart self.packages.${system}.syncPodmanStart ];
          };
        });
    };
}
