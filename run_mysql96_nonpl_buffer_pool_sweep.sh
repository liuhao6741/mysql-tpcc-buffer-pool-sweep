#!/bin/bash
# Run a MySQL 9.6 HammerDB TPC-C buffer-pool sweep in non-PL mode.
#
# If the MySQL 9.6 data-preparation wrapper is still running, this script waits
# for it to finish before starting the sweep. This avoids two jobs fighting over
# the same mysql96 container and /data/1/data96 datadir.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

export HAMMERDB_DIR="${HAMMERDB_DIR:-/opt/hammerdb}"
export MYSQL_IMAGE="${MYSQL_IMAGE:-mysql:9.6.0}"
export CONTAINER="${CONTAINER:-mysql96}"
export BACKUP_DIR="${BACKUP_DIR:-/data/1/pbackup96}"
export DATA_DIR="${DATA_DIR:-/data/1/data96}"
export CNF="${CNF:-$SCRIPT_DIR/mysql97.cnf}"
export CNF_MOUNT="${CNF_MOUNT:-/etc/my.cnf}"
export DATA_UID="${DATA_UID:-27}"

export SWEEP_SIZES_GIB="${SWEEP_SIZES_GIB:-10 30 50 70 90 110}"
export RAMPUP_MIN="${RAMPUP_MIN:-10}"
export DURATION_MIN="${DURATION_MIN:-60}"
export NUM_VU="${NUM_VU:-80}"
export TC_REFRESH_SEC="${TC_REFRESH_SEC:-1}"
export HDB_SSL="${HDB_SSL:-false}"
export HDB_NO_STORED_PROCS="${HDB_NO_STORED_PROCS:-true}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; exit 1; }

wait_for_current_prepare() {
    local prep_pattern="$SCRIPT_DIR/run_mysql96_nonpl_10g_once.sh"
    while pgrep -f "$prep_pattern" >/dev/null 2>&1; do
        log "Waiting for current MySQL 9.6 data-preparation job to finish"
        sleep 60
    done
}

wait_for_backup_ready() {
    while [[ ! -f "$BACKUP_DIR/ibdata1" && ! -d "$BACKUP_DIR/mysql" ]]; do
        if ! pgrep -f "$SCRIPT_DIR/run_mysql96_nonpl_10g_once.sh" >/dev/null 2>&1; then
            die "Backup $BACKUP_DIR is not ready and no data-preparation job is running"
        fi
        log "Waiting for backup $BACKUP_DIR to become a valid MySQL datadir"
        sleep 60
    done
}

install_mysql_client_wrapper() {
    # The host mysql client is MariaDB and does not support --ssl-mode. The
    # sweep harness uses one TLS login to prime MySQL 9.x caching_sha2_password
    # before HammerDB runs with HDB_SSL=false, so route that client call into the
    # mysql96 container.
    local bench_bin="${BENCH_BIN:-/tmp/bench-bin-mysql96-sweep}"
    mkdir -p "$bench_bin"
    cat > "$bench_bin/mysql" <<'MYSQL_WRAPPER'
#!/bin/bash
args=()
for arg in "$@"; do
  case "$arg" in
    --ssl-ca=/data/1/data96/ca.pem)
      args+=("--ssl-ca=/var/lib/mysql/ca.pem")
      ;;
    *)
      args+=("$arg")
      ;;
  esac
done
exec docker exec mysql96 mysql "${args[@]}"
MYSQL_WRAPPER
    chmod +x "$bench_bin/mysql"
    export PATH="$bench_bin:$PATH"
}

wait_for_backup_ready
wait_for_current_prepare
install_mysql_client_wrapper

log "Starting MySQL 9.6 non-PL buffer-pool sweep: $SWEEP_SIZES_GIB"
cd "$SCRIPT_DIR"

# sweep_buffer_pool.sh does not yet have a first-class 9.6 profile. Reuse the
# 9.x profile for auth/container semantics and override every version-specific
# runtime parameter above. The actual server version is recorded from
# SELECT VERSION() in each run.json.
MYSQL_PROFILE=9.7 ./sweep_buffer_pool.sh

# Rename the completed result directory so follow-up analysis sees mysql9.6 in
# the path instead of the 9.x selector used internally.
latest_dir=$(ls -dt "$SCRIPT_DIR"/results/*-mysql9.7 2>/dev/null | head -1 || true)
if [[ -n "$latest_dir" && -f "$latest_dir/bp-10GiB/run.json" ]] \
    && grep -q '"image": "mysql:9.6.0"' "$latest_dir/bp-10GiB/run.json"; then
    target_dir="${latest_dir%-mysql9.7}-mysql9.6"
    if [[ ! -e "$target_dir" ]]; then
        mv "$latest_dir" "$target_dir"
        log "Renamed result directory to $target_dir"
    else
        log "Result directory $target_dir already exists; keeping $latest_dir"
    fi
fi

log "MySQL 9.6 non-PL buffer-pool sweep complete"
