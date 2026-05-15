#!/bin/bash
# Prepare MySQL 9.6 TPC-C data and run one 10 GiB non-PL benchmark.
#
# The benchmark logic stays in sweep_buffer_pool.sh. This wrapper only handles
# the MySQL 9.6 runtime parameters and the one-time data preparation requested
# for /data/1/data96 and /data/1/pbackup96.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

HAMMERDB_DIR="${HAMMERDB_DIR:-/opt/hammerdb}"
MYSQL_IMAGE="${MYSQL_IMAGE:-mysql:9.6.0}"
CONTAINER="${CONTAINER:-mysql96}"
DATA_DIR="${DATA_DIR:-/data/1/data96}"
BACKUP_DIR="${BACKUP_DIR:-/data/1/pbackup96}"
CNF="${CNF:-$SCRIPT_DIR/mysql97.cnf}"
CNF_MOUNT="${CNF_MOUNT:-/etc/my.cnf}"
DATA_UID="${DATA_UID:-27}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; exit 1; }

[[ -x "$HAMMERDB_DIR/hammerdbcli" ]] || die "HammerDB not found at $HAMMERDB_DIR"
[[ -f "$CNF" ]] || die "MySQL config not found at $CNF"

prime_caching_sha2() {
    local ca="$DATA_DIR/ca.pem"
    [[ -f "$ca" ]] || die "ca.pem not found at $ca"
    docker exec "$CONTAINER" mysql \
        -h 127.0.0.1 -P 3306 -uroot -prootpassword \
        --ssl-mode=VERIFY_CA --ssl-ca=/var/lib/mysql/ca.pem \
        -e "SELECT 1;" >/dev/null
}

wait_for_mysql() {
    log "Waiting for MySQL 9.6 to accept connections"
    for _ in {1..120}; do
        if docker exec "$CONTAINER" mysqladmin ping -uroot -prootpassword --silent >/dev/null 2>&1; then
            log "MySQL is ready"
            return 0
        fi
        sleep 2
    done
    docker logs --tail 50 "$CONTAINER" >&2 || true
    die "MySQL did not become ready in time"
}

start_mysql_for_load() {
    log "Starting $CONTAINER for TPC-C data load"
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    rm -rf "$DATA_DIR" "$BACKUP_DIR"
    mkdir -p "$DATA_DIR" "$BACKUP_DIR"
    chown -R "${DATA_UID}:${DATA_UID}" "$DATA_DIR"

    docker run -d \
        --name "$CONTAINER" \
        --restart no \
        -e MYSQL_ROOT_PASSWORD=rootpassword \
        -e MYSQL_ROOT_HOST=% \
        -v "$DATA_DIR":/var/lib/mysql \
        -v "$CNF":"$CNF_MOUNT":ro \
        --network host \
        "$MYSQL_IMAGE" >/dev/null

    wait_for_mysql
    prime_caching_sha2
}

load_tpcc_data() {
    log "Loading HammerDB TPC-C data into MySQL 9.6"
    rm -f /tmp/hammer.DB /tmp/generic.db /tmp/mysql.db
    (
        cd "$SCRIPT_DIR"
        HAMMERDB_DIR="$HAMMERDB_DIR" HDB_SSL=false ./hammerdb_load.sh
    )
}

snapshot_data() {
    log "Stopping MySQL before snapshot"
    docker stop -t 120 "$CONTAINER" >/dev/null
    docker rm "$CONTAINER" >/dev/null 2>&1 || true

    log "Snapshotting $DATA_DIR to $BACKUP_DIR"
    rsync -a --delete "$DATA_DIR/" "$BACKUP_DIR/"
}

run_benchmark() {
    local bench_bin="${BENCH_BIN:-/tmp/bench-bin-mysql96}"
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

    log "Running MySQL 9.6 10 GiB non-PL benchmark"
    (
        cd "$SCRIPT_DIR"
        PATH="$bench_bin:$PATH" \
        HAMMERDB_DIR="$HAMMERDB_DIR" \
        MYSQL_PROFILE=9.7 \
        MYSQL_IMAGE="$MYSQL_IMAGE" \
        CONTAINER="$CONTAINER" \
        BACKUP_DIR="$BACKUP_DIR" \
        DATA_DIR="$DATA_DIR" \
        CNF="$CNF" \
        CNF_MOUNT="$CNF_MOUNT" \
        DATA_UID="$DATA_UID" \
        SWEEP_SIZES_GIB=10 \
        RAMPUP_MIN=10 \
        DURATION_MIN=10 \
        HDB_SSL=false \
        HDB_NO_STORED_PROCS=true \
        ./sweep_buffer_pool.sh
    )
}

start_mysql_for_load
load_tpcc_data
snapshot_data
run_benchmark

log "MySQL 9.6 data preparation and benchmark complete"
