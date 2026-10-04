{ pkgs }:
pkgs.writeShellApplication {
  name = "sync-podman-start";
  runtimeInputs = [ pkgs.coreutils pkgs.git pkgs.podman pkgs.podman-compose ];
  text = ''
    root=$(git rev-parse --show-toplevel)
    pods="''${1:-1}"
    case "$pods" in *[!0-9]*|0) printf 'pods must be a positive integer\n' >&2; exit 2;; esac
    state="$root/.state/sync-podman"
    compose="$state/compose.yml"
    nginx="$state/nginx.conf"
    containerfile="$state/Containerfile"
    mkdir -p "$state"
    sed 's/RUN cargo build --release --locked --bin server/RUN CARGO_BUILD_JOBS=1 RUSTFLAGS=-Cdebuginfo=0 cargo build --release --locked --bin server/' "$root/../xyne-sync-ref/docker/server/Dockerfile" > "$containerfile"
    podman build -t xyne-sync-ref:local -f "$containerfile" "$root/../xyne-sync-ref"
    {
      printf 'services:\n'
      for index in $(seq 0 $((pods - 1))); do
        port=4848
        test "$index" -gt 0 && port=$((4850 + index))
        cat <<EOF
  sync-$index:
    image: xyne-sync-ref:local
    environment:
      XYNE_SYNC_ADDR: "0.0.0.0:4848"
      XYNE_SYNC_BASE_PATH: "/zero"
      XYNE_SYNC_PG_DSN: "postgresql://xyne:xyne123@host.containers.internal:5433/xyne_dev_db"
      XYNE_SYNC_SCHEMAS: "public,zero_0"
      XYNE_SYNC_PUBLICATION: "xyne_sync_pub"
      XYNE_SYNC_DDL_TRIGGER: "zero_ddl_end_0"
      XYNE_SYNC_DDL_PREFIX: "zero/0/ddl"
      XYNE_SYNC_QUERY_URL: "http://host.containers.internal:3001/api/zero/query"
      XYNE_SYNC_MUTATE_URL: "http://host.containers.internal:3001/api/zero/push"
      XYNE_SYNC_FORWARD_COOKIES: "true"
      XYNE_SYNC_SLOT_CLEANUP_AGE_MS: "60000"
    ports:
      - "$port:4848"
EOF
      done
      cat <<EOF
  sync-proxy:
    image: nginx:alpine
    ports:
      - "4847:4847"
    volumes:
      - "$nginx:/etc/nginx/nginx.conf:ro"
EOF
    } > "$compose"
    {
      cat <<'EOF'
events {}
http {
  access_log /dev/stdout;
  error_log /dev/stderr;
  upstream xyne_sync {
    ip_hash;
EOF
      for index in $(seq 0 $((pods - 1))); do printf '    server sync-%s:4848;\n' "$index"; done
      cat <<'EOF'
  }
  server {
    listen 4847;
    location / {
      proxy_http_version 1.1;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection "upgrade";
      proxy_read_timeout 1h;
      proxy_pass http://xyne_sync;
    }
  }
}
EOF
    } > "$nginx"
    cleanup() { podman-compose -f "$compose" down 2>/dev/null || true; }
    trap cleanup EXIT INT TERM
    podman-compose -f "$compose" up
  '';
}
