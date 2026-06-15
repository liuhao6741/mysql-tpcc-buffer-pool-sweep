#!/bin/bash
# One-shot TiDB launcher via Docker. Starts three official containers:
#   tidb-pd   — Placement Driver   (pingcap/pd)
#   tidb-tikv — TiKV storage node  (pingcap/tikv)
#   tidb-tidb — TiDB SQL server    (pingcap/tidb)
#
# Override env vars:
#   TIDB_VERSION      version for all three images (default: v8.5.6)
#   TIDB_PORT         TiDB SQL port                 (default: 4000)
#   DATA_DIR          cluster data directory        (default: /obdata/data/tidb)
#   BLOCK_CACHE_SIZE  TiKV block-cache size         (default: 110G)
#   TIDB_USER / TIDB_PASS  MySQL-protocol credentials
#
# Run:
#   ./start_tidb.sh
#   BLOCK_CACHE_SIZE=50G TIDB_PORT=4001 ./start_tidb.sh

set -euo pipefail

TIDB_VERSION="${TIDB_VERSION:-v8.5.6}"
TIDB_PORT="${TIDB_PORT:-4000}"
DATA_DIR="${DATA_DIR:-/obdata/data/tidb}"
BLOCK_CACHE_SIZE="${BLOCK_CACHE_SIZE:-110G}"
PD_PORT="${PD_PORT:-2379}"

TIDB_HOST="${TIDB_HOST:-127.0.0.1}"
TIDB_USER="${TIDB_USER:-root}"
TIDB_PASS="${TIDB_PASS:-rootpassword}"

TIDB_PD_CONTAINER="${TIDB_PD_CONTAINER:-tidb-pd}"
TIDB_TIKV_CONTAINER="${TIDB_TIKV_CONTAINER:-tidb-tikv}"
TIDB_TIDB_CONTAINER="${TIDB_TIDB_CONTAINER:-tidb-tidb}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
die()  { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; exit 1; }

# ── prerequisite checks ───────────────────────────────────────────────
command -v docker >/dev/null 2>&1 || die "docker not found"
command -v mysql >/dev/null 2>&1 || die "mysql client not found"

# ── render TiKV config ────────────────────────────────────────────────
mkdir -p "$DATA_DIR/pd" "$DATA_DIR/tikv"
TIKV_CONFIG="$DATA_DIR/tikv.toml"

cat > "$TIKV_CONFIG" <<TOML
[storage]
block-cache = { capacity = "${BLOCK_CACHE_SIZE}" }

[rocksdb]
max-background-jobs = 8
max-open-files = 65536

[raftdb]
max-background-jobs = 4

[rocksdb.titan]
enabled = false

[raftstore]
capacity = "512GiB"
TOML

log "TiKV config written to $TIKV_CONFIG (block-cache=${BLOCK_CACHE_SIZE})"

# ── stop any previous instances ────────────────────────────────────────
for c in "$TIDB_TIDB_CONTAINER" "$TIDB_TIKV_CONTAINER" "$TIDB_PD_CONTAINER"; do
    if docker ps --format '{{.Names}}' | grep -qx "$c"; then
        log "Stopping existing $c"
        docker stop -t 120 "$c" >/dev/null
    fi
    docker rm "$c" >/dev/null 2>&1 || true
done

# ── start PD ───────────────────────────────────────────────────────────
log "Starting $TIDB_PD_CONTAINER (pingcap/pd:${TIDB_VERSION})"
docker run -d \
    --name "$TIDB_PD_CONTAINER" \
    --restart no \
    -v "$DATA_DIR/pd":/data \
    --network host \
    "pingcap/pd:${TIDB_VERSION}" \
    --name=pd \
    --peer-urls=http://127.0.0.1:2380 \
    --client-urls=http://127.0.0.1:${PD_PORT} \
    --advertise-client-urls=http://${TIDB_HOST}:${PD_PORT} \
    --initial-cluster=pd=http://127.0.0.1:2380 \
    --data-dir=/data >/dev/null

log "Waiting for PD to become healthy..."
for i in $(seq 1 120); do
    status=$(docker inspect -f '{{.State.Status}}' "$TIDB_PD_CONTAINER" 2>/dev/null || echo missing)
    if [[ "$status" == "exited" || "$status" == "dead" ]]; then
        log "PD container exited. Last 30 log lines:"
        docker logs --tail 30 "$TIDB_PD_CONTAINER" 2>&1 | sed 's/^/  /' >&2
        die "PD container exited (status=$status)"
    fi
    if curl -s "http://${TIDB_HOST}:${PD_PORT}/health" >/dev/null 2>&1; then
        log "PD healthy after ${i}s"
        break
    fi
    sleep 1
done
curl -s "http://${TIDB_HOST}:${PD_PORT}/health" >/dev/null 2>&1 \
    || die "PD did not become healthy in time"

# ── start TiKV ─────────────────────────────────────────────────────────
log "Starting $TIDB_TIKV_CONTAINER with block-cache=${BLOCK_CACHE_SIZE} (pingcap/tikv:${TIDB_VERSION})"
docker run -d \
    --name "$TIDB_TIKV_CONTAINER" \
    --restart no \
    -v "$DATA_DIR/tikv":/data \
    -v "$TIKV_CONFIG":/etc/tikv/tikv.toml:ro \
    --network host \
    "pingcap/tikv:${TIDB_VERSION}" \
    --pd="http://127.0.0.1:${PD_PORT}" \
    --config=/etc/tikv/tikv.toml \
    --addr=127.0.0.1:20160 \
    --advertise-addr=${TIDB_HOST}:20160 \
    --data-dir=/data >/dev/null

log "Waiting for TiKV to register with PD..."
for i in $(seq 1 120); do
    status=$(docker inspect -f '{{.State.Status}}' "$TIDB_TIKV_CONTAINER" 2>/dev/null || echo missing)
    if [[ "$status" == "exited" || "$status" == "dead" ]]; then
        log "TiKV container exited. Last 30 log lines:"
        docker logs --tail 30 "$TIDB_TIKV_CONTAINER" 2>&1 | sed 's/^/  /' >&2
        die "TiKV container exited (status=$status)"
    fi
    if curl -s "http://${TIDB_HOST}:${PD_PORT}/pd/api/v1/stores" 2>/dev/null \
        | grep -q '"state_name"[[:space:]]*:[[:space:]]*"Up"'; then
        log "TiKV store up after ${i}s"
        break
    fi
    sleep 1
done
curl -s "http://${TIDB_HOST}:${PD_PORT}/pd/api/v1/stores" 2>/dev/null \
    | grep -q '"state_name"[[:space:]]*:[[:space:]]*"Up"' \
    || die "TiKV did not register with PD in time"

# ── start TiDB ─────────────────────────────────────────────────────────
TIDB_CONFIG="$SCRIPT_DIR/tidb.toml"
log "Starting $TIDB_TIDB_CONTAINER (pingcap/tidb:${TIDB_VERSION})"
tidb_args=(
    --store=tikv
    --path=${TIDB_HOST}:${PD_PORT}
    --host=0.0.0.0
    -P "$TIDB_PORT"
)
tidb_vols=()
if [[ -f "$TIDB_CONFIG" ]]; then
    tidb_vols+=(-v "$TIDB_CONFIG":/etc/tidb/tidb.toml:ro)
    tidb_args+=(--config=/etc/tidb/tidb.toml)
fi
docker run -d \
    --name "$TIDB_TIDB_CONTAINER" \
    --restart no \
    --network host \
    "${tidb_vols[@]}" \
    "pingcap/tidb:${TIDB_VERSION}" \
    "${tidb_args[@]}" >/dev/null

log "Waiting for TiDB to accept connections on 127.0.0.1:$TIDB_PORT..."
_wait_args=(-h 127.0.0.1 -P "$TIDB_PORT" -u "$TIDB_USER")

for i in $(seq 1 300); do
    status=$(docker inspect -f '{{.State.Status}}' "$TIDB_TIDB_CONTAINER" 2>/dev/null || echo missing)
    if [[ "$status" == "exited" || "$status" == "dead" ]]; then
        log "TiDB container exited. Last 30 log lines:"
        docker logs --tail 30 "$TIDB_TIDB_CONTAINER" 2>&1 | sed 's/^/  /' >&2
        die "TiDB container exited (status=$status)"
    fi
    if mysql "${_wait_args[@]}" -e 'SELECT 1' >/dev/null 2>&1; then
        log "TiDB ready after ${i}s"
        break
    fi
    sleep 1
done

mysql "${_wait_args[@]}" -e 'SELECT 1' >/dev/null 2>&1 \
    || die "TiDB did not become ready in time"

log "TiDB version: $(mysql "${_wait_args[@]}" -N -B -e 'SELECT VERSION();' 2>/dev/null)"

# ── set root password ─────────────────────────────────────────────────
if [[ -n "$TIDB_PASS" ]]; then
    log "Setting root password..."
    mysql "${_wait_args[@]}" \
        -e "ALTER USER 'root'@'%' IDENTIFIED BY '$TIDB_PASS';" 2>/dev/null || true
fi

# ── create tpcc database (utf8mb4 to avoid latin1 collation errors) ───
_pass_args=(-h 127.0.0.1 -P "$TIDB_PORT" -u "$TIDB_USER" -p"$TIDB_PASS")
log "Creating tpcc database..."
mysql "${_pass_args[@]}" \
    -e "CREATE DATABASE IF NOT EXISTS tpcc CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;" 2>/dev/null

# ── apply benchmark tuning ────────────────────────────────────────────
log "Applying TiDB benchmark tuning..."
mysql "${_pass_args[@]}" <<SQL
SET GLOBAL max_execution_time = 0;
SET GLOBAL tidb_mem_quota_query = 34359738368;
SET GLOBAL tidb_enable_auto_analyze = OFF;
SET GLOBAL tidb_txn_mode = 'pessimistic';
SQL

log "TiDB tuning applied."
log "Ready for benchmarks — connect with: mysql -h 127.0.0.1 -P $TIDB_PORT -u root"
log "Containers: $TIDB_PD_CONTAINER $TIDB_TIKV_CONTAINER $TIDB_TIDB_CONTAINER"
