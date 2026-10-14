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
                psql "$primary" -v ON_ERROR_STOP=1 -f "$root/../temp/streamgres/scripts/sql/ddl-triggers.sql"
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
          syncArt = pkgs.writeShellApplication {
            name = "sync-art";
            runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.git pkgs.lsof pkgs.nodejs pkgs.postgresql pkgs.util-linux pkgs.cargo pkgs.rustc pkgs.stdenv.cc ];
            text = ''
              root=$(git rev-parse --show-toplevel)
              state="$root/.state/sync-art"
              repo="$state/streamgres"
              worktrees="$state/worktrees"
              base_target="$state/target/base"
              feature_target="$state/target/feature"
              base="''${1:?usage: sync-art <base-branch> <feature-branch>}"
              feature="''${2:?usage: sync-art <base-branch> <feature-branch>}"
              dsn="''${XYNE_SYNC_PG_DSN:-postgresql://xyne:xyne123@127.0.0.1:5433/xyne_dev_db}"
              query_url="''${XYNE_SYNC_QUERY_URL:-http://127.0.0.1:3001/api/zero/query}"
              mutate_url="''${XYNE_SYNC_MUTATE_URL:-http://127.0.0.1:3001/api/zero/push}"
              mkdir -p "$worktrees" "$state"
              stop_existing() {
                port="$1"
                for pid in $(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true); do
                  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
                  case "$command" in
                    *"$state/target/"*"/release/server"*)
                      printf 'Stopping prior sync-art server on port %s (pid %s)\n' "$port" "$pid"
                      kill -TERM "$pid" 2>/dev/null || true
                      attempt=0
                      while kill -0 "$pid" 2>/dev/null && test "$attempt" -lt 50; do sleep 0.2; attempt=$((attempt + 1)); done
                      if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; fi
                      ;;
                    *)
                      printf 'Port %s is occupied by an unrelated process (pid %s): %s\n' "$port" "$pid" "$command" >&2
                      return 1
                      ;;
                  esac
                done
              }
              stop_existing 4948
              stop_existing 4949
              if test ! -d "$repo/.git"; then
                git clone git@github.com:juspay/streamgres.git "$repo"
              fi
              git -C "$repo" fetch --prune origin
              resolve_branch() {
                if git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$1"; then
                  printf 'refs/remotes/origin/%s' "$1"
                elif git -C "$repo" show-ref --verify --quiet "refs/heads/$1"; then
                  printf 'refs/heads/%s' "$1"
                else
                  printf 'unknown branch: %s\n' "$1" >&2; return 2
                fi
              }
              base_ref=$(resolve_branch "$base")
              feature_ref=$(resolve_branch "$feature")
              base_dir="$worktrees/base"
              feature_dir="$worktrees/feature"
              for spec in "base:$base_ref:$base_dir" "feature:$feature_ref:$feature_dir"; do
                name=''${spec%%:*}; rest=''${spec#*:}; ref=''${rest%%:*}; dir=''${rest#*:}
                if test -e "$dir/.git"; then
                  git -C "$repo" worktree remove --force "$dir"
                fi
                git -C "$repo" worktree add --detach "$dir" "$ref"
                printf '%s branch %s at %s\n' "$name" "$ref" "$(git -C "$dir" rev-parse --short HEAD)"
              done
              printf 'Building base branch (before ART servers start)\n'
              cargo build --release --bin server --manifest-path "$base_dir/Cargo.toml" --target-dir "$base_target"
              printf 'Building feature branch (before ART servers start)\n'
              cargo build --release --bin server --manifest-path "$feature_dir/Cargo.toml" --target-dir "$feature_target"
              mkdir -p "$state"
              base_pid=""
              feature_pid=""
              # Called indirectly by the EXIT trap.
              # shellcheck disable=SC2329
              cleanup() {
                printf '\nStopping ART servers...\n'
                test -z "''${base_pid:-}" || kill "$base_pid" 2>/dev/null || true
                test -z "''${feature_pid:-}" || kill "$feature_pid" 2>/dev/null || true
                test -z "''${base_pid:-}" || wait "$base_pid" 2>/dev/null || true
                test -z "''${feature_pid:-}" || wait "$feature_pid" 2>/dev/null || true
                printf 'ART servers stopped.\n'
              }
              trap cleanup EXIT
              trap 'exit 130' INT
              trap 'exit 143' TERM
              run_server() {
                target="$1" port="$2" path="$3" logfile="$4"
                XYNE_SYNC_ADDR="127.0.0.1:$port" \
                XYNE_SYNC_BASE_PATH="$path" \
                XYNE_SYNC_PG_DSN="$dsn" \
                XYNE_SYNC_QUERY_URL="$query_url" \
                XYNE_SYNC_MUTATE_URL="$mutate_url" \
                XYNE_SYNC_SCHEMAS="''${XYNE_SYNC_SCHEMAS:-public,zero_0}" \
                XYNE_SYNC_PUBLICATION="''${XYNE_SYNC_PUBLICATION:-xyne_sync_pub}" \
                XYNE_SYNC_DDL_TRIGGER="''${XYNE_SYNC_DDL_TRIGGER:-zero_ddl_end_0}" \
                XYNE_SYNC_DDL_PREFIX="''${XYNE_SYNC_DDL_PREFIX:-zero/0/ddl}" \
                  exec "$target/release/server" >> "$logfile" 2>&1
              }
              run_server "$base_target" 4948 /zero/art-base "$state/base.log" &
              base_pid=$!
              run_server "$feature_target" 4949 /zero/art-feature "$state/feature.log" &
              feature_pid=$!
              printf 'Waiting for Streamgres branches to become ready.\nBase WebSocket: ws://127.0.0.1:4948/zero/art-base/sync/v51/connect\nFeature WebSocket: ws://127.0.0.1:4949/zero/art-feature/sync/v51/connect\nLogs: %s\n' "$state"
              until curl --fail --silent http://127.0.0.1:4948/zero/art-base/health >/dev/null; do sleep 1; done
              until curl --fail --silent http://127.0.0.1:4949/zero/art-feature/health >/dev/null; do sleep 1; done
              channel_id=$(psql "$dsn" -Atqc 'SELECT id FROM public.channels ORDER BY id LIMIT 1' 2>/dev/null || true)
              group_id=$(psql "$dsn" -Atqc 'SELECT id FROM public.user_groups ORDER BY id LIMIT 1' 2>/dev/null || true)
              client_status=0
              XYNE_SYNC_ART_CHANNEL_ID="$channel_id" \
              XYNE_SYNC_ART_GROUP_ID="$group_id" \
                node "$root/scripts/sync-art-clients.mjs" || client_status=$?
              exit "$client_status"
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
          inherit syncArt;
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
            packages = [ pkgs.git pkgs.just pkgs.nginx pkgs.podman pkgs.podman-compose pkgs.postgresql self.packages.${system}.start self.packages.${system}.spacesStart self.packages.${system}.syncStart self.packages.${system}.syncArt self.packages.${system}.metricsStart self.packages.${system}.syncPodmanStart ];
          };
        });
    };
}
