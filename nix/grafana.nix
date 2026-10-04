{ pkgs }:
let
  grafanaConfig = pkgs.writeText "grafana.ini" ''
    [server]
    http_addr = 127.0.0.1
    http_port = 3000
    [security]
    admin_user = admin
    admin_password = admin
  '';
  datasource = pkgs.writeText "datasource.yml" ''
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        access: proxy
        url: http://127.0.0.1:9090
        isDefault: true
  '';
  provider = pkgs.writeText "provider.yml" ''
    apiVersion: 1
    providers:
      - name: Xyne Sync
        type: file
        disableDeletion: true
        updateIntervalSeconds: 10
        options:
          path: __STATE__/dashboards
  '';
  dashboard = pkgs.writeText "xyne-sync.json" ''
    {
      "title": "Xyne Sync",
      "uid": "xyne-sync",
      "schemaVersion": 39,
      "refresh": "5s",
      "time": {"from": "now-15m", "to": "now"},
      "panels": [
        {"type":"timeseries","title":"Transactions / second","gridPos":{"h":8,"w":12,"x":0,"y":0},"targets":[{"expr":"rate(xyne_sync_transactions_total[5m])","legendFormat":"transactions"}]},
        {"type":"timeseries","title":"Writes / second","gridPos":{"h":8,"w":12,"x":12,"y":0},"targets":[{"expr":"rate(xyne_sync_writes_total[5m])","legendFormat":"writes"}]},
        {"type":"timeseries","title":"End-to-end p95","gridPos":{"h":8,"w":12,"x":0,"y":8},"fieldConfig":{"defaults":{"unit":"s"}},"targets":[{"expr":"histogram_quantile(0.95, sum by (le) (rate(xyne_sync_end_to_end_seconds_bucket[5m])))","legendFormat":"p95"}]},
        {"type":"timeseries","title":"Open connections","gridPos":{"h":8,"w":12,"x":12,"y":8},"targets":[{"expr":"xyne_sync_connections_open","legendFormat":"connections"}]},
        {"type":"timeseries","title":"CPU usage","gridPos":{"h":8,"w":12,"x":0,"y":16},"fieldConfig":{"defaults":{"unit":"percent"}},"targets":[{"expr":"100 * rate(xyne_sync_engine_busy_seconds_total[5m])","legendFormat":"engine"},{"expr":"100 * sum by (thread) (rate(xyne_sync_thread_cpu_seconds_total[5m]))","legendFormat":"{{thread}}"}]},
        {"type":"timeseries","title":"Hydration p95","gridPos":{"h":8,"w":12,"x":12,"y":16},"fieldConfig":{"defaults":{"unit":"s"}},"targets":[{"expr":"histogram_quantile(0.95, sum by (le, kind) (rate(xyne_sync_hydrate_seconds_bucket[5m])))","legendFormat":"{{kind}}"}]}
      ]
    }
  '';
in
pkgs.writeShellApplication {
  name = "metrics-start";
  runtimeInputs = [ pkgs.coreutils pkgs.git pkgs.grafana pkgs.prometheus ];
  text = ''
    root=$(git rev-parse --show-toplevel)
    pods="''${1:-1}"
    case "$pods" in *[!0-9]*|0) printf 'pods must be a positive integer\n' >&2; exit 2;; esac
    state="$root/.state/metrics"
    mkdir -p "$state/dashboards" "$state/provisioning/dashboards" "$state/provisioning/datasources" "$state/grafana/plugins"
    rm -f "$state/prometheus.yml" "$state/grafana.ini" "$state/provisioning/datasources/prometheus.yml" "$state/provisioning/dashboards/provider.yml" "$state/dashboards/xyne-sync.json"
    {
      printf 'global:\n  scrape_interval: 5s\nscrape_configs:\n  - job_name: xyne-sync\n    static_configs:\n      - targets: ['
      for index in $(seq 0 $((pods - 1))); do
        test "$index" -gt 0 && printf ', '
        port=4848
        test "$index" -gt 0 && port=$((4850 + index))
        printf '127.0.0.1:%s' "$port"
      done
      printf ']\n    metrics_path: /metrics\n'
    } > "$state/prometheus.yml"
    cp ${grafanaConfig} "$state/grafana.ini"
    cp ${datasource} "$state/provisioning/datasources/prometheus.yml"
    sed "s|__STATE__|$state|g" ${provider} > "$state/provisioning/dashboards/provider.yml"
    cp ${dashboard} "$state/dashboards/xyne-sync.json"
    prometheus --config.file="$state/prometheus.yml" --storage.tsdb.path="$state/prometheus" > "$state/prometheus.log" 2>&1 &
    prometheus_pid=$!
    trap 'kill "$prometheus_pid" 2>/dev/null || true' EXIT INT TERM
    GF_PATHS_DATA="$state/grafana" GF_PATHS_LOGS="$state/grafana/log" GF_PATHS_PLUGINS="$state/grafana/plugins" GF_PATHS_PROVISIONING="$state/provisioning" grafana server --homepath=${pkgs.grafana}/share/grafana --config="$state/grafana.ini"
  '';
}
