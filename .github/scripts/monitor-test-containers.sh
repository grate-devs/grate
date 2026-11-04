#!/usr/bin/env bash
# Invoke under GNU timeout so its process group owns this script and the event stream.
set -uo pipefail

results_directory=${1:?Usage: monitor-test-containers.sh RESULTS_DIRECTORY}
diagnostics_directory="$results_directory/container-diagnostics"
mkdir -p "$diagnostics_directory"
monitor_started_at=$(date -u +'%Y-%m-%dT%H:%M:%S.%NZ')

capture_container_failure() {
  local container_id=$1 exit_code=$2 image=$3 capture_directory
  [[ "$container_id" =~ ^[a-f0-9]{64}$ ]] || return 0
  [[ "$exit_code" =~ ^[0-9]{1,3}$ ]] || return 0
  (( 10#$exit_code > 0 && 10#$exit_code <= 255 )) || return 0
  case "$image" in
    mcr.microsoft.com/mssql/server:*|mcr.microsoft.com/mssql/server@*|postgres:*|postgres@*|mariadb:*|mariadb@*|gvenzl/oracle-*:*|gvenzl/oracle-*@*) ;;
    *) return 0 ;;
  esac

  capture_directory="$diagnostics_directory/$(date -u +'%Y%m%dT%H%M%S.%NZ')-$container_id"
  mkdir -p "$capture_directory"
  {
    printf 'Observed at: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%S.%NZ')"
    printf 'Container die event: id=%s exitCode=%s image=%s\n' "$container_id" "$exit_code" "$image"
  } | tee "$capture_directory/event.txt"

  # Explicit fields only: inspect must never dump environment variables or credentials.
  # Docker's Go-template variables $i/$m must remain literal shell text.
  # shellcheck disable=SC2016
  if ! timeout --foreground --kill-after=2s 10s docker inspect --format '{"id":{{json .Id}},"state":{"status":{{json .State.Status}},"exitCode":{{.State.ExitCode}},"oomKilled":{{.State.OOMKilled}},"error":{{json .State.Error}},"startedAt":{{json .State.StartedAt}},"finishedAt":{{json .State.FinishedAt}}},"limits":{"memory":{{.HostConfig.Memory}},"memorySwap":{{.HostConfig.MemorySwap}},"nanoCpus":{{.HostConfig.NanoCpus}},"cpuQuota":{{.HostConfig.CpuQuota}},"cpuPeriod":{{.HostConfig.CpuPeriod}},"pidsLimit":{{json .HostConfig.PidsLimit}},"ulimits":{{json .HostConfig.Ulimits}},"shmSize":{{.HostConfig.ShmSize}}},"mounts":[{{range $i,$m := .Mounts}}{{if $i}},{{end}}{"type":{{json $m.Type}},"name":{{json (index $m "Name")}},"destination":{{json $m.Destination}}}{{end}}]}' "$container_id" > "$capture_directory/inspect.json" 2> "$capture_directory/inspect-error.txt"; then
    printf 'Container inspection failed or timed out; it may already have been removed.\n' >> "$capture_directory/inspect-error.txt"
  fi
  cat "$capture_directory/inspect.json" "$capture_directory/inspect-error.txt"

  if ! timeout --foreground --kill-after=2s 10s docker logs --timestamps --tail 200 "$container_id" > "$capture_directory/container.log" 2>&1; then
    printf '\nContainer log capture failed or timed out; it may already have been removed.\n' >> "$capture_directory/container.log"
  fi
  cat "$capture_directory/container.log"
}

watch_container_failures() {
  docker events --since "$monitor_started_at" --filter type=container --filter event=die \
    --format '{{.Actor.ID}} {{index .Actor.Attributes "exitCode"}} {{index .Actor.Attributes "image"}}' |
    while read -r container_id exit_code image extra; do
      [[ -z "$extra" ]] || continue
      capture_container_failure "$container_id" "$exit_code" "$image"
    done
}

sample_resources() {
  {
    echo '::group::Test host and container resources'
    date -u +'%Y-%m-%dT%H:%M:%S.%NZ'
    free -h
    printf "Host limits: processes=%s open-files=%s\n" "$(ulimit -u)" "$(ulimit -n)"
    df -h / /dev/shm
    timeout --foreground --kill-after=2s 10s docker ps -a --format 'table {{.ID}}\t{{.Image}}\t{{.Status}}\t{{.Names}}' || true
    timeout --foreground --kill-after=2s 10s docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.BlockIO}}\t{{.PIDs}}' || true
    timeout --foreground --kill-after=2s 10s docker image ls --digests --format '{{.Repository}}@{{.Digest}} {{.ID}}' || true
    echo '::endgroup::'
  } | tee -a "$diagnostics_directory/resources.log"
}

watch_container_failures &
events_pid=$!
stop_events() {
  trap - EXIT
  kill "$events_pid" 2>/dev/null || true
  wait "$events_pid" 2>/dev/null || true
}
trap stop_events EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# Capture an initial sample too: a database can die before the first 60-second interval.
while true; do
  sample_resources
  sleep 60
done
