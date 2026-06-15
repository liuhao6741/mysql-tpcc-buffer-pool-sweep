#!/bin/bash
# Sweep TiKV storage.block-cache.capacity and run HammerDB TPC-C at each
# setting. The block-cache is TiKV's SSTable data-block read cache — roughly
# analogous to InnoDB's buffer-pool. This script sweeps it through a range
# of sizes (default 10–110 GiB), running a full HammerDB TPC-C timed
# workload at each step.
#
# TiDB is deployed as three Docker containers (official PingCAP images):
#   tidb-pd   — Placement Driver   (pingcap/pd:TAG)
#   tidb-tikv — TiKV storage node  (pingcap/tikv:TAG)
#   tidb-tidb — TiDB SQL server    (pingcap/tidb:TAG)
#
# All three share the host network (--network host) and a common data
# directory on the host.
#
# Per iteration:
#   1. Stop containers in reverse order (tidb → tikv → pd).
#   2. rsync /obdata/data/backup/tidb/ -> /obdata/data/tidb/ (clean known-good snapshot).
#   3. Drop OS page cache.
#   4. Render tikv.toml with the target block-cache size.
#   5. Start PD → wait healthy → start TiKV → wait store up → start TiDB.
#   6. Apply TiDB benchmark tuning via SET GLOBAL.
#   7. Start per-second collectors and run HammerDB (no stored procedures).
#
# Config (override via env):
#   SWEEP_SIZES_GIB="10 30 50 70 90 110"  block-cache sizes to sweep
#   NUM_VU=80                              virtual users
#   RAMPUP_MIN=10 DURATION_MIN=60          HammerDB pacing
#   TC_REFRESH_SEC=1                       1-sec TPM counter
#   TIDB_VERSION=v8.5.6                    version tag for all three images
#   BACKUP_DIR=/obdata/data/backup/tidb     clean snapshot source
#   DATA_DIR=/obdata/data/tidb              live cluster data
#   TIDB_PORT=4000                         TiDB SQL port
#   TIDB_USER=root / TIDB_PASS=""          MySQL-protocol credentials
#
# Output (per iteration under results/<ts>-tidb/bp-<N>GiB/):
#   run.json              — full config manifest
#   hammerdb_run.out      — jobid + timing / tcount / result
#   hammerdbcli.out       — raw hammerdbcli stdout
#   hdbtcount_*.log       — per-second transaction-counter logs
#   tpm_1sec.csv          — extracted per-second TPM from cli output
#   nopm_1sec.csv         — external d_next_o_id sampler (raw)
#   nopm_rate_1sec.csv    — derived per-second NOPM rate
#   result.txt            — computed NOPM + window
#   qps.csv               — 1-sec MySQL QPS/TPS/thread counters
#   vmstat.log iostat.log mpstat.log turbostat.tsv
#   tidb_variables_*.txt  — SHOW GLOBAL VARIABLES bracketing the run
#   system_info.txt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HAMMERDB_DIR="${HAMMERDB_DIR:-/opt/HammerDB-5.0}"

# ── knobs ──────────────────────────────────────────────────────────────
TIDB_VERSION="${TIDB_VERSION:-v8.5.6}"

# Official PingCAP images on Docker Hub.
TIDB_PD_IMAGE="${TIDB_PD_IMAGE:-pingcap/pd:${TIDB_VERSION}}"
TIDB_TIKV_IMAGE="${TIDB_TIKV_IMAGE:-pingcap/tikv:${TIDB_VERSION}}"
TIDB_TIDB_IMAGE="${TIDB_TIDB_IMAGE:-pingcap/tidb:${TIDB_VERSION}}"

TIDB_PD_CONTAINER="${TIDB_PD_CONTAINER:-tidb-pd}"
TIDB_TIKV_CONTAINER="${TIDB_TIKV_CONTAINER:-tidb-tikv}"
TIDB_TIDB_CONTAINER="${TIDB_TIDB_CONTAINER:-tidb-tidb}"

TIDB_HOST="${TIDB_HOST:-127.0.0.1}"
TIDB_PORT="${TIDB_PORT:-4000}"
TIDB_USER="${TIDB_USER:-root}"
TIDB_PASS="${TIDB_PASS:-rootpassword}"
PD_PORT="${PD_PORT:-2379}"

BACKUP_DIR="${BACKUP_DIR:-/obdata/data/backup/tidb}"
DATA_DIR="${DATA_DIR:-/obdata/data/tidb}"

if [[ -n "${SWEEP_SIZES_GIB:-}" ]]; then
    # shellcheck disable=SC2206
    SIZES_GIB=($SWEEP_SIZES_GIB)
else
    SIZES_GIB=(10 30 50 70 90 110)
fi

NUM_VU="${NUM_VU:-80}"
RAMPUP_MIN="${RAMPUP_MIN:-10}"
DURATION_MIN="${DURATION_MIN:-60}"
TC_REFRESH_SEC="${TC_REFRESH_SEC:-1}"

TS=$(date +%Y%m%d-%H%M%S)
RESULTS_ROOT="$SCRIPT_DIR/results/$TS-tidb"
mkdir -p "$RESULTS_ROOT"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
die()  { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; exit 1; }

[[ -x "$HAMMERDB_DIR/hammerdbcli" ]] || die "HammerDB not found at $HAMMERDB_DIR"
[[ -d "$BACKUP_DIR" ]]              || die "Backup $BACKUP_DIR missing — load schema first with hammerdb_load_tidb.sh"
command -v mysql >/dev/null 2>&1    || die "mysql client not found"

# Verify backup looks like a TiDB cluster datadir.
[[ -d "$BACKUP_DIR/pd" ]]  || die "$BACKUP_DIR does not look like a TiDB datadir (missing pd/)"
[[ -d "$BACKUP_DIR/tikv" ]] || die "$BACKUP_DIR does not look like a TiDB datadir (missing tikv/)"

# ── helpers ────────────────────────────────────────────────────────────

tidb_cli() {
    local pass_args=(-h "$TIDB_HOST" -P "$TIDB_PORT" -u "$TIDB_USER")
    [[ -n "$TIDB_PASS" ]] && pass_args+=(-p"$TIDB_PASS")
    mysql "${pass_args[@]}" "$@"
}

render_tikv_config() {
    local size_gib="$1"
    cat <<TOML
[storage]
# Block cache for SSTable data blocks. This is the primary read cache —
# roughly analogous to InnoDB buffer pool.
block-cache = { capacity = "${size_gib}GiB" }

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
}

# ── lifecycle ──────────────────────────────────────────────────────────

stop_tidb() {
    for c in "$TIDB_TIDB_CONTAINER" "$TIDB_TIKV_CONTAINER" "$TIDB_PD_CONTAINER"; do
        if docker ps --format '{{.Names}}' | grep -qx "$c"; then
            log "Stopping $c"
            docker stop -t 120 "$c" >/dev/null
        fi
        docker rm "$c" >/dev/null 2>&1 || true
    done
}

restore_datadir() {
    local backup_real data_real
    backup_real=$(readlink -f "$BACKUP_DIR" 2>/dev/null || echo "$BACKUP_DIR")
    data_real=$(readlink -f "$DATA_DIR" 2>/dev/null || echo "$DATA_DIR")
    if [[ "$backup_real" == "$data_real" ]]; then
        log "BACKUP_DIR and DATA_DIR are the same path — skipping restore"
        return 0
    fi
    log "Restoring $DATA_DIR from $BACKUP_DIR"
    rm -rf "$DATA_DIR"
    mkdir -p "$DATA_DIR"
    rsync -a --delete "$BACKUP_DIR/" "$DATA_DIR/"
}

drop_os_cache() {
    log "Dropping OS page cache"
    sync
    if [[ -w /proc/sys/vm/drop_caches ]]; then
        echo 3 > /proc/sys/vm/drop_caches
    elif command -v sudo >/dev/null 2>&1; then
        sudo sh -c 'sync && echo 3 > /proc/sys/vm/drop_caches'
    else
        log "WARN: cannot drop OS caches (not root, no sudo)"
    fi
}

start_tidb() {
    local size_gib="$1"
    local cnf_path="$2"

    # --- PD ---
    log "Starting $TIDB_PD_CONTAINER ($TIDB_PD_IMAGE)"
    docker run -d \
        --name "$TIDB_PD_CONTAINER" \
        --restart no \
        -v "$DATA_DIR/pd":/data \
        --network host \
        "$TIDB_PD_IMAGE" \
        --name=pd \
        --peer-urls=http://127.0.0.1:2380 \
        --client-urls=http://127.0.0.1:${PD_PORT} \
        --advertise-client-urls=http://${TIDB_HOST}:${PD_PORT} \
        --initial-cluster=pd=http://127.0.0.1:2380 \
        --data-dir=/data >/dev/null

    log "Waiting for PD to become healthy"
    local status
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

    # --- TiKV ---
    log "Starting $TIDB_TIKV_CONTAINER with block-cache=${size_gib}GiB ($TIDB_TIKV_IMAGE)"
    docker run -d \
        --name "$TIDB_TIKV_CONTAINER" \
        --restart no \
        -v "$DATA_DIR/tikv":/data \
        -v "$cnf_path":/etc/tikv/tikv.toml:ro \
        --network host \
        "$TIDB_TIKV_IMAGE" \
        --pd=http://127.0.0.1:${PD_PORT} \
        --config=/etc/tikv/tikv.toml \
        --addr=127.0.0.1:20160 \
        --advertise-addr=${TIDB_HOST}:20160 \
        --data-dir=/data >/dev/null

    log "Waiting for TiKV to register with PD"
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

    # --- TiDB ---
    log "Starting $TIDB_TIDB_CONTAINER ($TIDB_TIDB_IMAGE)"
    local tidb_args=(
        --store=tikv
        --path=${TIDB_HOST}:${PD_PORT}
        --host=0.0.0.0
        -P "$TIDB_PORT"
    )
    local tidb_vols=()
    local tidb_config="$SCRIPT_DIR/tidb.toml"
    if [[ -f "$tidb_config" ]]; then
        tidb_vols+=(-v "$tidb_config":/etc/tidb/tidb.toml:ro)
        tidb_args+=(--config=/etc/tidb/tidb.toml)
    fi
    docker run -d \
        --name "$TIDB_TIDB_CONTAINER" \
        --restart no \
        --network host \
        "${tidb_vols[@]}" \
        "$TIDB_TIDB_IMAGE" \
        "${tidb_args[@]}" >/dev/null

    log "Waiting for TiDB to accept connections (up to 5 min)"
    for i in $(seq 1 300); do
        status=$(docker inspect -f '{{.State.Status}}' "$TIDB_TIDB_CONTAINER" 2>/dev/null || echo missing)
        if [[ "$status" == "exited" || "$status" == "dead" ]]; then
            log "TiDB container exited. Last 30 log lines:"
            docker logs --tail 30 "$TIDB_TIDB_CONTAINER" 2>&1 | sed 's/^/  /' >&2
            die "TiDB container exited (status=$status)"
        fi
        if tidb_cli -e 'SELECT 1' >/dev/null 2>&1; then
            log "TiDB ready after ${i}s"
            return 0
        fi
        sleep 1
    done
    die "TiDB did not become ready in time"
}

# ── tuning ─────────────────────────────────────────────────────────────

apply_tuning() {
    log "Applying TiDB benchmark tuning"
    tidb_cli <<SQL >/dev/null 2>&1 || log "WARN: some tuning statements failed"
SET GLOBAL max_execution_time = 0;
SET GLOBAL tidb_mem_quota_query = 34359738368;
SET GLOBAL tidb_enable_auto_analyze = OFF;
SET GLOBAL tidb_txn_mode = 'pessimistic';
SQL

    local actual
    actual=$(tidb_cli -N -B -e "SELECT @@GLOBAL.tidb_txn_mode;" 2>/dev/null)
    log "tidb_txn_mode = ${actual:-?}"
    actual=$(tidb_cli -N -B -e "SELECT @@GLOBAL.tidb_enable_auto_analyze;" 2>/dev/null)
    log "tidb_enable_auto_analyze = ${actual:-?}"

    sleep 10
}

# ── snapshots ──────────────────────────────────────────────────────────

dump_variables() {
    local path="$1"
    tidb_cli -e "
        SHOW GLOBAL VARIABLES LIKE '%tidb%';
        SHOW GLOBAL VARIABLES LIKE '%tikv%';
        SHOW GLOBAL VARIABLES LIKE '%txn%';
        SHOW GLOBAL VARIABLES LIKE '%memory%';
        SHOW GLOBAL VARIABLES LIKE '%cache%';
    " 2>/dev/null > "$path" || true
}

dump_status() {
    local path="$1"
    {
        echo "=== SHOW GLOBAL STATUS (key counters) ==="
        tidb_cli -e "
            SHOW GLOBAL STATUS WHERE Variable_name IN (
                'Com_commit','Com_rollback','Questions',
                'Threads_running','Threads_connected',
                'Uptime','Bytes_sent','Bytes_received'
            );
        " 2>/dev/null || true
        echo ""
        echo "=== SHOW PROCESSLIST ==="
        tidb_cli -e "SHOW FULL PROCESSLIST;" 2>/dev/null || true
    } > "$path" || true
}

dump_system_info() {
    local path="$1"
    {
        echo "=== uname ==="; uname -a || true
        echo ""
        echo "=== CPU ==="; lscpu 2>/dev/null || true
        echo ""
        echo "=== Memory ==="; free -h || true
        echo ""
        echo "=== Disk ==="; df -h "$DATA_DIR" "$BACKUP_DIR" 2>/dev/null || true
        echo ""
        echo "=== Block device ==="
        local dev candidate="$DATA_DIR"
        while [[ "$candidate" != "/" && -z "${dev:-}" ]]; do
            dev=$(findmnt -n -o SOURCE "$candidate" 2>/dev/null || true)
            candidate=$(dirname "$candidate")
        done
        [[ -n "${dev:-}" ]] && { echo "datadir backed by: $dev"; lsblk -o NAME,SIZE,TYPE,ROTA,MODEL "$dev" 2>/dev/null || true; }
        echo ""
        echo "=== VM tunables ==="
        sysctl vm.swappiness vm.dirty_ratio vm.dirty_background_ratio 2>/dev/null || true
        echo ""
        echo "=== THP ==="
        cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
        cat /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
    } > "$path" || true
}

# ── collectors ─────────────────────────────────────────────────────────

_collect_qps() {
    local outfile="$1"
    local prev_q="" prev_cc="" prev_cr=""
    echo "timestamp,questions,qps,com_commit,com_rollback,tps,threads_running,threads_connected" > "$outfile"
    while true; do
        local stats
        stats=$(tidb_cli -N \
            -e "SHOW GLOBAL STATUS WHERE Variable_name IN ('Questions','Com_commit','Com_rollback','Threads_running','Threads_connected');" 2>/dev/null) \
            || { sleep 1; continue; }
        local q cc cr tr tc
        q=$(echo "$stats"  | awk '/^Questions/ {print $2}')
        cc=$(echo "$stats" | awk '/^Com_commit/ {print $2}')
        cr=$(echo "$stats" | awk '/^Com_rollback/ {print $2}')
        tr=$(echo "$stats" | awk '/^Threads_running/ {print $2}')
        tc=$(echo "$stats" | awk '/^Threads_connected/ {print $2}')
        q=${q:-0}; cc=${cc:-0}; cr=${cr:-0}; tr=${tr:-0}; tc=${tc:-0}
        local ts qps tps
        ts=$(date '+%Y-%m-%d %H:%M:%S')
        qps=0; tps=0
        if [[ -n "$prev_q" ]]; then
            qps=$(( q - prev_q ))
            tps=$(( (cc - prev_cc) + (cr - prev_cr) ))
        fi
        echo "${ts},${q},${qps},${cc},${cr},${tps},${tr},${tc}" >> "$outfile"
        prev_q=$q; prev_cc=$cc; prev_cr=$cr
        sleep 1
    done
}

_collect_nopm() {
    local outfile="$1"
    echo "timestamp,elapsed_sec,sum_next_o_id" > "$outfile"
    local start=$(date +%s)
    while true; do
        local ts elapsed val
        ts=$(date '+%Y-%m-%d %H:%M:%S')
        elapsed=$(( $(date +%s) - start ))
        val=$(tidb_cli tpcc -N -B -e "SELECT SUM(d_next_o_id) FROM district;" 2>/dev/null | head -1)
        echo "${ts},${elapsed},${val:-}" >> "$outfile"
        sleep 1
    done
}

start_collectors() {
    local iter_dir="$1"
    local total_secs=$(( (RAMPUP_MIN + DURATION_MIN) * 60 + 600 ))
    COLLECTOR_PIDS=()
    command -v vmstat >/dev/null && { vmstat 1 "$total_secs" > "$iter_dir/vmstat.log" 2>&1 & COLLECTOR_PIDS+=($!); }
    command -v iostat >/dev/null && { iostat -xdm 1 "$total_secs" > "$iter_dir/iostat.log" 2>&1 & COLLECTOR_PIDS+=($!); }
    command -v mpstat >/dev/null && { mpstat -P ALL 1 "$total_secs" > "$iter_dir/mpstat.log" 2>&1 & COLLECTOR_PIDS+=($!); }
    _collect_qps  "$iter_dir/qps.csv"          & COLLECTOR_PIDS+=($!)
    _collect_nopm "$iter_dir/nopm_1sec.csv"    & COLLECTOR_PIDS+=($!)
    log "Started collectors (${#COLLECTOR_PIDS[@]} pids)"
}

stop_collectors() {
    local pid
    for pid in "${COLLECTOR_PIDS[@]:-}"; do
        [[ -n "$pid" ]] || continue
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    COLLECTOR_PIDS=()
}

# ── HammerDB ──────────────────────────────────────────────────────────

run_hammerdb() {
    local outfile="$1"
    local logfile="$2"
    local total_sec=$(( (RAMPUP_MIN + DURATION_MIN) * 60 ))
    local startup_slack=20
    log "Running HammerDB (rampup=${RAMPUP_MIN}m duration=${DURATION_MIN}m num_vu=${NUM_VU}, no_stored_procs)"

    (
        cd "$HAMMERDB_DIR"
        HDB_NUM_VU="$NUM_VU" \
        HDB_RAMPUP="$RAMPUP_MIN" \
        HDB_DURATION="$DURATION_MIN" \
        HDB_TC_RATE="$TC_REFRESH_SEC" \
        HDB_OUTFILE="$outfile" \
            ./hammerdbcli auto "$SCRIPT_DIR/hammerdb_run_tidb.tcl"
    ) > "$logfile" 2>&1 &
    local hdb_pid=$!
    log "HammerDB pid=$hdb_pid, will run ${total_sec}s then terminate"

    local deadline=$(( $(date +%s) + total_sec + startup_slack ))
    while kill -0 "$hdb_pid" 2>/dev/null; do
        if (( $(date +%s) >= deadline )); then
            log "Measurement window over — terminating HammerDB"
            kill -TERM "$hdb_pid" 2>/dev/null || true
            pkill -TERM -P "$hdb_pid" 2>/dev/null || true
            sleep 3
            kill -KILL "$hdb_pid" 2>/dev/null || true
            pkill -KILL -P "$hdb_pid" 2>/dev/null || true
            break
        fi
        sleep 2
    done
    wait "$hdb_pid" 2>/dev/null || true

    pgrep -f "hammerdbcli auto.*hammerdb_run_tidb.tcl" \
        | xargs -r kill -TERM 2>/dev/null || true
    sleep 2
    pgrep -f "hammerdbcli auto.*hammerdb_run_tidb.tcl" \
        | xargs -r kill -KILL 2>/dev/null || true
    log "HammerDB terminated"
}

# ── manifest ──────────────────────────────────────────────────────────

write_manifest() {
    local iter_dir="$1" size_gib="$2"
    local manifest="$iter_dir/run.json"
    local ver
    ver=$(tidb_cli -N -B -e "SELECT VERSION();" 2>/dev/null | head -1)
    local kernel_ver host_ram_gib cpu_governor
    kernel_ver=$(uname -r)
    host_ram_gib=$(awk -v kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)" 'BEGIN{printf "%.2f", kb/1024/1024}')
    cpu_governor=$(cut -d' ' -f1 /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort -u | paste -sd ',' || echo unknown)

    local cpu_idle_enabled="unknown"
    if [[ -d /sys/devices/system/cpu/cpu0/cpuidle ]]; then
        cpu_idle_enabled=$(
            for s in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
                if [[ "$(cat "$s/disable" 2>/dev/null)" == "0" ]]; then
                    cat "$s/name"
                fi
            done | paste -sd,
        ) || true
        [[ -z "$cpu_idle_enabled" ]] && cpu_idle_enabled="none"
    fi

    local swappiness thp_enabled thp_defrag
    swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo unknown)
    thp_enabled=$(awk -F'[][]' '{print $2}' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)
    thp_defrag=$(awk -F'[][]' '{print $2}' /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null)
    [[ -z "$thp_enabled" ]] && thp_enabled="unknown"
    [[ -z "$thp_defrag" ]] && thp_defrag="unknown"

    cat > "$manifest" <<JSON
{
  "timestamp_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "benchmark": {
    "tool": "HammerDB",
    "tool_version": "5.0",
    "workload": "TPC-C",
    "driver": "timed",
    "num_virtual_users": $NUM_VU,
    "warehouses": 1000,
    "rampup_minutes": $RAMPUP_MIN,
    "duration_minutes": $DURATION_MIN,
    "tc_refresh_seconds": $TC_REFRESH_SEC,
    "allwarehouse": true,
    "timeprofile": false,
    "no_stored_procs": true
  },
  "database": {
    "engine": "tidb",
    "version": "${ver:-unknown}",
    "pd_image": "$TIDB_PD_IMAGE",
    "tikv_image": "$TIDB_TIKV_IMAGE",
    "tidb_image": "$TIDB_TIDB_IMAGE",
    "host": "$TIDB_HOST",
    "port": $TIDB_PORT
  },
  "tikv": {
    "block_cache_size_gib": $size_gib,
    "replicas": 1,
    "rocksdb_max_background_jobs": 8,
    "titan_enabled": false
  },
  "paths": {
    "backup_dir": "$BACKUP_DIR",
    "data_dir": "$DATA_DIR",
    "hammerdb_dir": "$HAMMERDB_DIR",
    "hammerdb_load_script": "$SCRIPT_DIR/hammerdb_load_tidb.tcl",
    "hammerdb_run_script": "$SCRIPT_DIR/hammerdb_run_tidb.tcl"
  },
  "host": {
    "hostname": "$(hostname)",
    "kernel": "$kernel_ver",
    "cpu_count": $(nproc),
    "ram_gib": $host_ram_gib,
    "cpu_governor": "$cpu_governor",
    "cpu_idle_states_enabled": "$cpu_idle_enabled",
    "vm_swappiness": $swappiness,
    "transparent_hugepages_enabled": "$thp_enabled",
    "transparent_hugepages_defrag": "$thp_defrag"
  }
}
JSON
}

# ── NOPM computation ──────────────────────────────────────────────────

compute_nopm() {
    local iter_dir="$1" size_gib="$2"
    local csv="$iter_dir/nopm_1sec.csv"
    local out="$iter_dir/result.txt"
    local rampup_sec=$(( RAMPUP_MIN * 60 ))
    local run_end_sec=$(( (RAMPUP_MIN + DURATION_MIN) * 60 ))

    if [[ ! -s "$csv" ]]; then
        echo "no nopm_1sec.csv — cannot compute NOPM" > "$out"
        return
    fi

    awk -F, -v rs="$rampup_sec" -v re="$run_end_sec" -v dur="$DURATION_MIN" -v sz="$size_gib" '
        NR==1 { next }
        $3 == "" { next }
        {
            e = $2 + 0
            v = $3 + 0
            if (e <= rs && e > best_start_e) { best_start_e = e; best_start_v = v; have_start = 1 }
            if (e <= re && e > best_end_e)   { best_end_e   = e; best_end_v   = v; have_end   = 1 }
        }
        END {
            if (!have_start || !have_end) {
                print "insufficient NOPM samples (start?" have_start " end?" have_end ")"
                exit
            }
            delta = best_end_v - best_start_v
            mins  = (best_end_e - best_start_e) / 60.0
            if (mins > 0) nopm = delta / mins; else nopm = 0
            printf "BLOCK_CACHE_SIZE_GIB=%s\n", sz
            printf "WINDOW_SEC_START=%d\n", best_start_e
            printf "WINDOW_SEC_END=%d\n",   best_end_e
            printf "WINDOW_MINUTES=%.4f\n", mins
            printf "SUM_D_NEXT_O_ID_START=%d\n", best_start_v
            printf "SUM_D_NEXT_O_ID_END=%d\n",   best_end_v
            printf "DELTA_ORDERS=%d\n", delta
            printf "NOPM=%d\n", nopm
        }
    ' "$csv" > "$out"

    awk -F, '
        NR==1 { print "elapsed_sec,sum_next_o_id,orders_delta,nopm_rate"; next }
        $3 == "" { next }
        {
            e = $2 + 0
            v = $3 + 0
            if (prev_e != "") {
                dt = e - prev_e
                dv = v - prev_v
                if (dt > 0) rate = dv * 60.0 / dt; else rate = 0
                printf "%d,%d,%d,%.1f\n", e, v, dv, rate
            } else {
                printf "%d,%d,0,0\n", e, v
            }
            prev_e = e; prev_v = v
        }
    ' "$csv" > "$iter_dir/nopm_rate_1sec.csv"

    local nopm
    nopm=$(awk -F= '/^NOPM=/ {print $2}' "$out")
    log "Result for ${size_gib}GiB: NOPM=${nopm:-?}"
}

trap 'log "Interrupted"; stop_collectors 2>/dev/null; stop_tidb; exit 130' INT TERM

# ── main sweep ────────────────────────────────────────────────────────

log "Sweep start — results under $RESULTS_ROOT"
log "Sizes (GiB): ${SIZES_GIB[*]}"
log "VU=$NUM_VU rampup=${RAMPUP_MIN}m duration=${DURATION_MIN}m"
log "Images: pd=$TIDB_PD_IMAGE  tikv=$TIDB_TIKV_IMAGE  tidb=$TIDB_TIDB_IMAGE"
log "Backup:  $BACKUP_DIR"
log "Datadir: $DATA_DIR"

for size in "${SIZES_GIB[@]}"; do
    iter_dir="$RESULTS_ROOT/bp-${size}GiB"
    mkdir -p "$iter_dir"
    log "===== Iteration: block-cache=${size}GiB ($iter_dir) ====="

    stop_tidb
    restore_datadir
    drop_os_cache

    cnf_path="$iter_dir/tikv.toml"
    render_tikv_config "$size" > "$cnf_path"

    start_tidb "$size" "$cnf_path"
    apply_tuning

    dump_variables   "$iter_dir/tidb_variables_before.txt"
    dump_status      "$iter_dir/tidb_status_before.txt"
    dump_system_info "$iter_dir/system_info.txt"
    write_manifest   "$iter_dir" "$size"

    mkdir -p /tmp/hdbtcount_archive
    mv /tmp/hdbtcount_*.log /tmp/hdbtcount_archive/ 2>/dev/null || true

    tb_iters=$(( (RAMPUP_MIN + DURATION_MIN) * 60 + 120 ))
    tb_pid=""
    if command -v turbostat >/dev/null; then
        turbostat --interval 1 --num_iterations "$tb_iters" --quiet \
            --show Package,Core,CPU,Avg_MHz,Busy%,Bzy_MHz,IPC,CoreTmp,PkgTmp,PkgWatt,RAMWatt,CPU%c1,CPU%c6 \
            > "$iter_dir/turbostat.tsv" 2>"$iter_dir/turbostat.err" &
        tb_pid=$!
    fi

    start_collectors "$iter_dir"

    run_hammerdb "$iter_dir/hammerdb_run.out" "$iter_dir/hammerdbcli.out"

    stop_collectors
    [[ -n "$tb_pid" ]] && kill -0 "$tb_pid" 2>/dev/null && { kill -TERM "$tb_pid" 2>/dev/null || true; wait "$tb_pid" 2>/dev/null || true; }

    for tc in /tmp/hdbtcount_*.log; do
        [[ -f "$tc" ]] && cp -f "$tc" "$iter_dir/$(basename "$tc")"
    done
    if [[ -f "$iter_dir/hammerdbcli.out" ]]; then
        awk '/MySQL tpm/ { if(n==0) print "second,tpm"; printf "%d,%d\n", n, $1; n++ }' \
            "$iter_dir/hammerdbcli.out" > "$iter_dir/tpm_1sec.csv"
    fi

    dump_variables "$iter_dir/tidb_variables_after.txt"
    dump_status    "$iter_dir/tidb_status_after.txt"

    compute_nopm "$iter_dir" "$size"

    log "Iteration ${size}GiB complete"
done

stop_tidb
log "Sweep done — results under $RESULTS_ROOT"
