''
  if [ "$(uname -s)" = Darwin ] && command -v podman >/dev/null && ! podman info >/dev/null 2>&1; then
    if ! podman machine inspect podman-machine-default >/dev/null 2>&1; then
      podman machine init podman-machine-default
    else
      podman machine stop podman-machine-default >/dev/null 2>&1 || true
    fi
    podman machine start podman-machine-default
    podman info >/dev/null
  fi
  script -q "$root/.state/spaces.log" nix develop "$spaces" --command env \
    XYNE_FEATURES=1 \
    XYNE_DEV_APPS=dashboard,backend,worker \
    VITE_ZERO_SERVER=http://127.0.0.1:4848 \
    ZERO_BIND_PORT_1=4849 \
    ZERO_BIND_PORT_2=4850 \
    pnpm --dir "$spaces" run up
''
