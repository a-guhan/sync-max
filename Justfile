start:
  nix develop --command start

start-spaces:
  nix develop --command spaces-start

start-sync pods="1":
  nix develop --command sync-start {{pods}}

kill:
  for pid in $(pgrep -f '/bin/start$$' || true); do if test "$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')" = "$PWD"; then kill "$pid" 2>/dev/null || true; fi; done
  pkill -TERM -f 'xyne-sync-ref/.*/server' || true
  pkill -TERM -f 'xyne-sync-ref/Cargo.toml' || true
  podman-compose -f "$PWD/.state/sync-podman/compose.yml" down 2>/dev/null || true
  pkill -TERM -f 'xyne-spaces.*pnpm.*run up' || true
  pkill -TERM -f '/sync-max/.state/(sync|spaces)\.log' || true
  pg_ctl -D "$PWD/.state/replica" -m fast stop 2>/dev/null || true
  podman stop xyne-spaces-postgres xyne-spaces-redis xyne-spaces-fake-gcs xyne-spaces-minio xyne-spaces-zero-cache 2>/dev/null || true
