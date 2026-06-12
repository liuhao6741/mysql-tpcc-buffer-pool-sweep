#!/bin/bash
# Sweep Percona Server MyRocks rocksdb_block_cache_size and run HammerDB TPC-C.
#
# One-time setup:
#   1. ./start_percona_rocksdb.sh
#   2. ./hammerdb_load_percona_rocksdb.sh
#   3. rsync -a --delete /data/rocksdb/ /backup/rocksdb/
#
# Per iteration:
#   1. Stop/remove Percona container.
#   2. Restore /backup/rocksdb -> /data/rocksdb.
#   3. Drop OS page cache.
#   4. Render per-iteration cnf with rocksdb_block_cache_size=<N>G.
#   5. Start Percona Server with MyRocks.
#   6. Collect host + MySQL telemetry and run HammerDB.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HAMMERDB_DIR="${HAMMERDB_DIR:-/opt/HammerDB-5.0}"

PERCONA_CONTAINER="${PERCONA_CONTAINER:-percona-rocksdb}"
PERCONA_IMAGE="${PERCONA_IMAGE:-percona/percona-server:8.0}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-rootpassword}"
BACKUP_DIR="${BACKUP_DIR:-/backup/rocksdb}"
DATA_DIR="${DATA_DIR:-/data/rocksdb}"
CNF="${CNF:-$SCRIPT_DIR/percona_rocksdb.cnf}"
CNF_MOUNT="${CNF_MOUNT:-/etc/my.cnf}"
PERCONA_DATA_UID="${PERCONA_DATA_UID:-1001}"

if [[ -n "${SWEEP_SIZES_GIB:-}" ]]; then
    # shellcheck disable=SC2206
    SIZES_GIB=($SWEEP_SIZES_GIB)
else
    SIZES_GIB=(${SIZES_GIB:-10 30 50 70 90 110})
fi

NUM_VU="${NUM_VU:-80}"
RAMPUP_MIN="${RAMPUP_MIN:-10}"
DURATION_MIN="${DURATION_MIN:-60}"
TC_REFRESH_SEC="${TC_REFRESH_SEC:-1}"
HDB_NO_STORED_PROCS="${HDB_NO_STORED_PROCS:-false}"

TS=$(date +%Y%m%d-%H%M%S)
RESULTS_ROOT="$SCRIPT_DIR/results/$TS-percona-rocksdb"
mkdir -p "$RESULTS_ROOT"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
die()  { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; exit 1; }

[[ -x "$HAMMERDB_DIR/hammerdbcli" ]] || die "HammerDB not found at $HAMMERDB_DIR"
[[ -d "$BACKUP_DIR" ]] || die "Backup directory $BACKUP_DIR missing"
[[ -f "$CNF" ]] || die "Percona MyRocks config $CNF missing"
[[ -f "$BACKUP_DIR/ibdata1" || -d "$BACKUP_DIR/mysql" ]] \
    || die "$BACKUP_DIR does not look like a MySQL datadir"

stop_percona() {
    if docker ps --format '{{.Names}}' | grep -qx "$PERCONA_CONTAINER"; then
        log "Stopping container $PERCONA_CONTAINER"
        docker stop -t 120 "$PERCONA_CONTAINER" >/dev/null
    fi
    docker rm "$PERCONA_CONTAINER" >/dev/null 2>&1 || true
}

restore_datadir() {
    log "Restoring $DATA_DIR from $BACKUP_DIR"
    rm -rf "$DATA_DIR"
    mkdir -p "$DATA_DIR"
    rsync -a --delete "$BACKUP_DIR/" "$DATA_DIR/"
    chown -R "${PERCONA_DATA_UID}:${PERCONA_DATA_UID}" "$DATA_DIR" 2>/dev/null || chmod -R u+rwX,go+rwX "$DATA_DIR"
}

drop_os_cache() {
    log "Dropping OS page cache"
    sync
    if [[ -w /proc/sys/vm/drop_caches ]]; then
        echo 3 > /proc/sys/vm/drop_caches
    elif command -v sudo >/dev/null 2>&1; then
        sudo sh -c 'sync && echo 3 > /proc/sys/vm/drop_caches'
    else
        die "Cannot write /proc/sys/vm/drop_caches — run as root or with sudo"
    fi
}

write_cnf_with_cache() {
    local cache_gib="$1"
    local out="$2"
    awk -v cache="${cache_gib}G" '
        /^(loose-)?rocksdb_block_cache_size/ {
            printf "loose-rocksdb_block_cache_size  = %s\n", cache
            next
        }
        { print }
    ' "$CNF" > "$out"
}

db_client() {
    docker exec "$PERCONA_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$@"
}

db_client_in() {
    docker exec -i "$PERCONA_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$@"
}

start_percona() {
    local cnf_path="$1"
    log "Starting Percona MyRocks container with $(grep -E '^(loose-)?rocksdb_block_cache_size' "$cnf_path" | tr -s ' ')"
    docker run -d \
        --name "$PERCONA_CONTAINER" \
        --restart no \
        -e MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD" \
        -e MYSQL_ROOT_HOST=% \
        -v "$DATA_DIR":/var/lib/mysql \
        -v "$cnf_path":"$CNF_MOUNT":ro \
        --network host \
        "$PERCONA_IMAGE" >/dev/null

    log "Waiting for Percona Server to accept connections"
    local status
    for _ in {1..180}; do
        status=$(docker inspect -f '{{.State.Status}}' "$PERCONA_CONTAINER" 2>/dev/null || echo missing)
        if [[ "$status" == "exited" || "$status" == "dead" ]]; then
            log "Container exited unexpectedly. Last 80 log lines:"
            docker logs --tail 80 "$PERCONA_CONTAINER" 2>&1 | sed 's/^/  /' >&2
            die "Percona container exited during startup (status=$status)"
        fi
        if docker exec "$PERCONA_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" \
                -N -B -e "SELECT 1;" >/dev/null 2>&1; then
            log "Percona ready"
            return 0
        fi
        sleep 2
    done
    die "Percona Server did not become ready in time"
}

ensure_native_auth() {
    db_client_in <<SQL >/dev/null
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED WITH mysql_native_password BY '$MYSQL_ROOT_PASSWORD';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY '$MYSQL_ROOT_PASSWORD';
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$MYSQL_ROOT_PASSWORD';
FLUSH PRIVILEGES;
SQL
}

ensure_rocksdb() {
    local cache_gib="${1:-}"
    # plugin-load-add should already load the engine; INSTALL PLUGIN is kept as
    # a best-effort fallback for datadirs created without plugin metadata.
    db_client -e "INSTALL PLUGIN ROCKSDB SONAME 'ha_rocksdb.so';" >/dev/null 2>&1 || true
    db_client -N -B -e "SHOW ENGINES;" 2>/dev/null | awk '$1 == "ROCKSDB" && $2 == "YES" {found=1} END {exit found ? 0 : 1}' \
        || die "ROCKSDB engine is not available"
    if [[ -n "$cache_gib" ]]; then
        local actual expected
        actual=$(db_client -N -B -e "SHOW VARIABLES LIKE 'rocksdb_block_cache_size';" 2>/dev/null | awk '{print $2}')
        expected=$(( cache_gib * 1024 * 1024 * 1024 ))
        [[ "$actual" == "$expected" ]] \
            || die "rocksdb_block_cache_size mismatch: expected $expected (${cache_gib}G), got ${actual:-empty}"
    fi
    db_client -e "SET GLOBAL transaction_isolation='READ-COMMITTED';" >/dev/null 2>&1 || true
    log "ROCKSDB engine verified"
}

dump_status() {
    local path="$1"
    db_client -e "
        SHOW GLOBAL VARIABLES LIKE 'rocksdb%';
        SHOW GLOBAL STATUS LIKE 'Rocksdb%';
        SHOW GLOBAL STATUS LIKE 'Com_commit';
        SHOW GLOBAL STATUS LIKE 'Com_rollback';
        SHOW GLOBAL STATUS LIKE 'Questions';
        SHOW GLOBAL STATUS LIKE 'Threads_%';
        SHOW GLOBAL STATUS LIKE 'Uptime';
    " 2>/dev/null > "$path" || true
}

dump_all_status() {
    local path="$1"
    db_client -e "SHOW GLOBAL STATUS;" 2>/dev/null > "$path" || true
}

dump_all_variables() {
    local path="$1"
    db_client -e "SHOW GLOBAL VARIABLES;" 2>/dev/null > "$path" || true
}

dump_rocksdb_status() {
    local path="$1"
    {
        db_client -e "SHOW ENGINE ROCKSDB STATUS\G" 2>/dev/null || true
        echo ""
        db_client -e "SELECT TABLE_NAME, ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA='tpcc' ORDER BY TABLE_NAME;" 2>/dev/null || true
    } > "$path" || true
}

dump_system_info() {
    local path="$1"
    {
        echo "=== uname ==="
        uname -a || true
        echo ""
        echo "=== CPU ==="
        lscpu 2>/dev/null || true
        echo ""
        echo "=== Memory ==="
        free -h || true
        echo ""
        echo "=== Disk (data + backup) ==="
        df -h "$DATA_DIR" "$BACKUP_DIR" 2>/dev/null || true
        echo ""
        echo "=== Kernel / VM tunables ==="
        sysctl vm.swappiness vm.dirty_ratio vm.dirty_background_ratio \
               vm.dirty_bytes vm.dirty_background_bytes \
               kernel.numa_balancing 2>/dev/null || true
        echo ""
        echo "=== THP ==="
        cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
        cat /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
        echo ""
        echo "=== NUMA ==="
        numactl --hardware 2>/dev/null | head -20 || true
    } > "$path" || true
}

_collect_qps() {
    local outfile="$1"
    local prev_q="" prev_cc="" prev_cr=""
    echo "timestamp,questions,qps,com_commit,com_rollback,tps,threads_running,threads_connected" > "$outfile"
    while true; do
        local stats
        stats=$(db_client -N \
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

start_collectors() {
    local iter_dir="$1"
    local total_secs=$(( (RAMPUP_MIN + DURATION_MIN) * 60 + 600 ))
    COLLECTOR_PIDS=()
    command -v vmstat >/dev/null && { vmstat 1 "$total_secs" > "$iter_dir/vmstat.log" 2>&1 & COLLECTOR_PIDS+=($!); }
    command -v iostat >/dev/null && { iostat -xdm 1 "$total_secs" > "$iter_dir/iostat.log" 2>&1 & COLLECTOR_PIDS+=($!); }
    command -v mpstat >/dev/null && { mpstat -P ALL 1 "$total_secs" > "$iter_dir/mpstat.log" 2>&1 & COLLECTOR_PIDS+=($!); }
    _collect_qps "$iter_dir/qps.csv" & COLLECTOR_PIDS+=($!)
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

run_hammerdb() {
    local outfile="$1"
    log "Running HammerDB (Percona MyRocks rampup=${RAMPUP_MIN}m duration=${DURATION_MIN}m num_vu=${NUM_VU})"
    cd "$HAMMERDB_DIR"
    HDB_NUM_VU="$NUM_VU" \
    HDB_RAMPUP="$RAMPUP_MIN" \
    HDB_DURATION="$DURATION_MIN" \
    HDB_TC_RATE="$TC_REFRESH_SEC" \
    HDB_OUTFILE="$outfile" \
    HDB_MYSQL_PASS="$MYSQL_ROOT_PASSWORD" \
    HDB_NO_STORED_PROCS="$HDB_NO_STORED_PROCS" \
        ./hammerdbcli auto "$SCRIPT_DIR/hammerdb_run_percona_rocksdb.tcl" 2>&1
    cd - >/dev/null
}

hammerdb_version() {
    ( "$HAMMERDB_DIR/hammerdbcli" </dev/null 2>&1 || true ) \
        | awk '/HammerDB CLI/ {sub(/^v/, "", $3); print $3; exit}'
}

percona_version_full() {
    db_client -N -B -e "SELECT VERSION();" 2>/dev/null || true
}

write_manifest() {
    local iter_dir="$1" cache_gib="$2"
    local manifest="$iter_dir/run.json"
    local percona_ver hdb_ver kernel_ver host_ram_kb host_ram_gib cpu_governor
    percona_ver=$(percona_version_full || true)
    hdb_ver=$(hammerdb_version || true)
    kernel_ver=$(uname -r)
    host_ram_kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo || true)
    host_ram_gib=$(awk -v kb="$host_ram_kb" 'BEGIN{printf "%.2f", kb/1024/1024}' || true)
    cpu_governor=$( { cut -d' ' -f1 /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null \
        | sort -u | paste -sd ','; } || true)
    [[ -z "$cpu_governor" ]] && cpu_governor="unknown"

    local swappiness thp_enabled thp_defrag warehouses
    swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo unknown)
    thp_enabled=$(awk -F'[][]' '{print $2}' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)
    thp_defrag=$(awk -F'[][]' '{print $2}' /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null)
    [[ -z "$thp_enabled" ]] && thp_enabled="unknown"
    [[ -z "$thp_defrag" ]] && thp_defrag="unknown"
    warehouses="${HDB_WAREHOUSES:-1000}"

    cat > "$manifest" <<JSON
{
  "timestamp_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "benchmark": {
    "tool": "HammerDB",
    "tool_version": "${hdb_ver:-5.0}",
    "workload": "TPC-C",
    "driver": "timed",
    "num_virtual_users": $NUM_VU,
    "warehouses": ${warehouses:-null},
    "rampup_minutes": $RAMPUP_MIN,
    "duration_minutes": $DURATION_MIN,
    "tc_refresh_seconds": $TC_REFRESH_SEC,
    "allwarehouse": true,
    "timeprofile": false,
    "no_stored_procs": $([[ "$HDB_NO_STORED_PROCS" == "true" ]] && echo true || echo false)
  },
  "database": {
    "engine": "mysql",
    "profile": "percona-rocksdb",
    "image": "$PERCONA_IMAGE",
    "version": "${percona_ver:-unknown}",
    "storage_engine": "rocksdb",
    "partitioned": false,
    "authentication": "mysql_native_password",
    "ssl": false
  },
  "rocksdb": {
    "block_cache_size_gib": $cache_gib,
    "transaction_isolation": "READ-COMMITTED"
  },
  "paths": {
    "backup_dir": "$BACKUP_DIR",
    "data_dir": "$DATA_DIR",
    "mysql_cnf": "$iter_dir/percona_rocksdb.cnf",
    "hammerdb_dir": "$HAMMERDB_DIR",
    "hammerdb_load_script": "$SCRIPT_DIR/hammerdb_load_percona_rocksdb.tcl",
    "hammerdb_run_script": "$SCRIPT_DIR/hammerdb_run_percona_rocksdb.tcl"
  },
  "host": {
    "hostname": "$(hostname)",
    "kernel": "$kernel_ver",
    "cpu_count": $(nproc),
    "ram_gib": $host_ram_gib,
    "cpu_governor": "$cpu_governor",
    "vm_swappiness": $swappiness,
    "transparent_hugepages_enabled": "$thp_enabled",
    "transparent_hugepages_defrag": "$thp_defrag"
  }
}
JSON
}

write_sysfs() {
    local path="$1" val="$2"
    if [[ -w "$path" ]]; then
        echo "$val" > "$path"
    elif command -v sudo >/dev/null 2>&1; then
        echo "$val" | sudo tee "$path" >/dev/null
    else
        die "Cannot write $path — run as root or with sudo"
    fi
}

set_cpu_performance() {
    local govs=(/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor)
    if [[ ! -e "${govs[0]}" ]]; then
        log "cpufreq not available — skipping governor change"
        return 0
    fi
    log "Setting all CPUs to performance governor"
    local g
    for g in "${govs[@]}"; do
        write_sysfs "$g" performance
    done
}

set_swappiness() {
    log "Setting vm.swappiness = 1"
    write_sysfs /proc/sys/vm/swappiness 1
}

disable_thp() {
    local enabled=/sys/kernel/mm/transparent_hugepage/enabled
    local defrag=/sys/kernel/mm/transparent_hugepage/defrag
    if [[ ! -f "$enabled" ]]; then
        log "THP sysfs not present — skipping"
        return 0
    fi
    log "Disabling Transparent Huge Pages"
    write_sysfs "$enabled" never
    write_sysfs "$defrag" never
}

trap 'log "Interrupted"; stop_collectors 2>/dev/null; stop_percona; exit 130' INT TERM

log "Percona MyRocks sweep start — results under $RESULTS_ROOT"
log "rocksdb_block_cache_size values (GiB): ${SIZES_GIB[*]}"

set_cpu_performance
set_swappiness
disable_thp

for size in "${SIZES_GIB[@]}"; do
    iter_dir="$RESULTS_ROOT/bp-${size}GiB"
    mkdir -p "$iter_dir"
    log "===== Iteration: rocksdb_block_cache_size=${size}GiB ($iter_dir) ====="

    stop_percona
    restore_datadir
    drop_os_cache

    cnf_path="$iter_dir/percona_rocksdb.cnf"
    write_cnf_with_cache "$size" "$cnf_path"

    start_percona "$cnf_path"
    ensure_native_auth
    ensure_rocksdb "$size"
    write_manifest "$iter_dir" "$size"

    dump_status        "$iter_dir/mysql_status_start.txt"
    dump_all_variables "$iter_dir/mysql_variables.txt"
    dump_all_status    "$iter_dir/mysql_status_before.txt"
    dump_system_info   "$iter_dir/system_info.txt"

    : > /tmp/hammerdb.log
    mkdir -p /tmp/hdbtcount_archive
    mv /tmp/hdbtcount_*.log /tmp/hdbtcount_archive/ 2>/dev/null || true

    tb_iters=$(( (RAMPUP_MIN + DURATION_MIN) * 60 + 120 ))
    if command -v turbostat >/dev/null 2>&1; then
        turbostat --interval 1 --num_iterations "$tb_iters" --quiet \
            --show Package,Core,CPU,Avg_MHz,Busy%,Bzy_MHz,IPC,CoreTmp,PkgTmp,PkgWatt,RAMWatt,CPU%c1,CPU%c6 \
            > "$iter_dir/turbostat.tsv" 2>"$iter_dir/turbostat.err" &
        tb_pid=$!
        log "turbostat sampling pid=$tb_pid"
    else
        log "turbostat not available — skipping CPU telemetry"
        tb_pid=""
    fi

    start_collectors "$iter_dir"
    run_hammerdb "$iter_dir/hammerdb_run.out" | tee "$iter_dir/hammerdbcli.out"
    cp -f /tmp/hammerdb.log "$iter_dir/hammerdb.log" 2>/dev/null || true
    stop_collectors

    if [[ -n "$tb_pid" ]] && kill -0 "$tb_pid" 2>/dev/null; then
        kill -TERM "$tb_pid" 2>/dev/null || true
        wait "$tb_pid" 2>/dev/null || true
    fi

    for tc in /tmp/hdbtcount_*.log; do
        [[ -f "$tc" ]] || continue
        cp -f "$tc" "$iter_dir/$(basename "$tc")"
    done

    if [[ -f "$iter_dir/hammerdbcli.out" ]]; then
        awk '
            /MySQL tpm/ {
                if (n == 0) print "second,tpm"
                printf "%d,%d\n", n, $1
                n++
            }
        ' "$iter_dir/hammerdbcli.out" > "$iter_dir/tpm_1sec.csv"
    fi

    dump_status         "$iter_dir/mysql_status_end.txt"
    dump_all_status     "$iter_dir/mysql_status_after.txt"
    dump_rocksdb_status "$iter_dir/rocksdb_status.txt"
    log "Iteration ${size}GiB complete"
done

stop_percona
log "Sweep done — results under $RESULTS_ROOT"
