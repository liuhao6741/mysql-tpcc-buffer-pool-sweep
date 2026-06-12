#!/bin/bash
# Sweep SeekDB MEMORY_LIMIT and run HammerDB 4.12 TPC-C at each setting.
#
# Identical pipeline to sweep_seekdb.sh but uses HammerDB 4.12 at
# /opt/HammerDB-4.2 instead of HammerDB 5.0. The run template is
# hammerdb412_run_seekdb.tcl with mysql_no_stored_procs=true.
#
# Per iteration:
#   1. Stop + remove the seekdb container.
#   2. rsync /backup/seekdb/ -> /data/seekdb/ (clean known-good snapshot).
#   3. Drop OS page cache.
#   4. Start seekdb with MEMORY_LIMIT=<size>G.
#   5. Apply SeekDB tuning (same as start_seekdb.sh).
#   6. Start per-second collectors and run HammerDB 4.12 (no stored procedures).
#
# Config (override via env):
#   SIZES_GIB="10 30 50 70 90 110"  memory_limit values to sweep
#   NUM_VU=80                       virtual users
#   RAMPUP_MIN=10 DURATION_MIN=60   HammerDB pacing
#   TC_REFRESH_SEC=1                1-sec TPM counter
#   BACKUP_DIR=/backup/seekdb       source of the clean snapshot
#   DATA_DIR=/data/seekdb           live SeekDB volume
#
# Output:
#   results/<ts>-seekdb-hdb412/bp-<N>GiB/
#       hammerdb_run.out + hammerdbcli.out + hdbtcount_*.log + tpm_1sec.csv
#       turbostat.tsv vmstat.log iostat.log mpstat.log qps.csv
#       seekdb_variables_*.txt, seekdb_status_*.txt
#       nopm_1sec.csv result.txt  (NOPM computed from d_next_o_id deltas)
#       run.json  system_info.txt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HAMMERDB_DIR="${HAMMERDB_DIR:-/opt/HammerDB-4.2}"
SEEKDB_CONTAINER="${SEEKDB_CONTAINER:-seekdb}"
SEEKDB_IMAGE="${SEEKDB_IMAGE:-quay.io/oceanbase/seekdb:latest}"
SEEKDB_HOST="${SEEKDB_HOST:-127.0.0.1}"
SEEKDB_PORT="${SEEKDB_PORT:-2881}"
SEEKDB_USER="${SEEKDB_USER:-root}"
SEEKDB_PASS="${SEEKDB_PASS:-password}"
BACKUP_DIR="${BACKUP_DIR:-/backup/seekdb}"
DATA_DIR="${DATA_DIR:-/data/seekdb}"

# Container-internal UID that seekdb runs as (the entrypoint chowns on
# first boot; we replicate here because rsync from a root-owned backup
# leaves wrong ownership).
SEEKDB_DATA_UID="${SEEKDB_DATA_UID:-0}"

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

TS=$(date +%Y%m%d-%H%M%S)
RESULTS_ROOT="$SCRIPT_DIR/results/$TS-seekdb-hdb412"
mkdir -p "$RESULTS_ROOT"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
die()  { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; exit 1; }

[[ -x "$HAMMERDB_DIR/hammerdbcli" ]] || die "HammerDB not found at $HAMMERDB_DIR"
[[ -d "$BACKUP_DIR" ]] || die "Backup $BACKUP_DIR missing — populate it first"

# ---------- helpers ----------

seekdb_cli() {
    mysql -h "$SEEKDB_HOST" -P "$SEEKDB_PORT" -u"$SEEKDB_USER" -p"$SEEKDB_PASS" "$@"
}

stop_seekdb() {
    if docker ps --format '{{.Names}}' | grep -qx "$SEEKDB_CONTAINER"; then
        log "Stopping $SEEKDB_CONTAINER"
        docker stop -t 120 "$SEEKDB_CONTAINER" >/dev/null
    fi
    docker rm "$SEEKDB_CONTAINER" >/dev/null 2>&1 || true
}

restore_datadir() {
    # Skip the wipe+rsync when BACKUP_DIR and DATA_DIR resolve to the same
    # filesystem path — otherwise `rm -rf "$DATA_DIR"` would delete the
    # "backup" too and leave SeekDB with an empty datadir.
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
    # SeekDB container runs as root (UID 0); keep tree permissions simple.
    chown -R "$SEEKDB_DATA_UID:$SEEKDB_DATA_UID" "$DATA_DIR" 2>/dev/null || true
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

start_seekdb() {
    local mem_gib="$1"
    log "Starting $SEEKDB_CONTAINER with MEMORY_LIMIT=${mem_gib}G"
    docker run -d \
        --name "$SEEKDB_CONTAINER" \
        --restart no \
        -e MEMORY_LIMIT="${mem_gib}G" \
        -e LOG_DISK_SIZE=32G \
        -e CPU_COUNT=0 \
        -e DATAFILE_MAXSIZE=512G \
        -e ROOT_PASSWORD="$SEEKDB_PASS" \
        -e SEEKDB_DATABASE=sbtest \
        -v "$DATA_DIR":/var/lib/oceanbase \
        --network host \
        "$SEEKDB_IMAGE" >/dev/null

    log "Waiting for SeekDB to accept connections (up to 5 min)"
    local status
    for i in $(seq 1 300); do
        status=$(docker inspect -f '{{.State.Status}}' "$SEEKDB_CONTAINER" 2>/dev/null || echo missing)
        if [[ "$status" == "exited" || "$status" == "dead" ]]; then
            log "Container exited unexpectedly. Last 30 log lines:"
            docker logs --tail 30 "$SEEKDB_CONTAINER" 2>&1 | sed 's/^/  /' >&2
            die "SeekDB container exited (status=$status)"
        fi
        if seekdb_cli -e 'SELECT 1' >/dev/null 2>&1; then
            log "SeekDB ready after ${i}s"
            return 0
        fi
        sleep 1
    done
    die "SeekDB did not become ready in time"
}

apply_tuning() {
    log "Applying SeekDB tuning"
    seekdb_cli <<'SQL' >/dev/null 2>&1 || log "WARN: some tuning statements failed"
ALTER SYSTEM SET _enable_defensive_check = FALSE;
ALTER SYSTEM SET _lcl_op_interval = '0ms';
ALTER SYSTEM SET syslog_level = 'ERROR';
ALTER SYSTEM SET micro_block_merge_verify_level = 0;
CALL DBMS_MONITOR.OB_TENANT_TRACE_DISABLE;
ALTER SYSTEM SET writing_throttling_trigger_percentage = 100;
ALTER SYSTEM SET freeze_trigger_percentage = 70;
ALTER SYSTEM SET enable_user_defined_rewrite_rules = TRUE;
SET GLOBAL ob_query_timeout = 3600000000;
SQL
}

# ---------- snapshots ----------

dump_variables() {
    local path="$1"
    seekdb_cli oceanbase \
        -e "SELECT name, value FROM GV\$OB_PARAMETERS WHERE name IN (
            'memory_limit','memstore_limit_percentage','freeze_trigger_percentage',
            'writing_throttling_trigger_percentage','_lcl_op_interval',
            '_enable_defensive_check','micro_block_merge_verify_level',
            'ob_query_timeout','syslog_level','enable_user_defined_rewrite_rules'
        ) ORDER BY name;" 2>/dev/null > "$path" || true
}

dump_tenant_status() {
    local path="$1"
    {
        echo "=== GV\$OB_TENANT_MEMORY ==="
        seekdb_cli oceanbase -e "SELECT HOLD, FREE, (HOLD+FREE) AS total FROM GV\$OB_TENANT_MEMORY;" 2>/dev/null || true
        echo ""
        echo "=== GV\$OB_UNITS ==="
        seekdb_cli oceanbase -e "SELECT MAX_CPU, MEMORY_SIZE, DATA_DISK_IN_USE, LOG_DISK_IN_USE, STATUS FROM GV\$OB_UNITS;" 2>/dev/null || true
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
        echo "=== VM tunables ==="
        sysctl vm.swappiness vm.dirty_ratio vm.dirty_background_ratio 2>/dev/null || true
        echo ""
        echo "=== THP ==="
        cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
    } > "$path"
}

# ---------- collectors ----------

_collect_qps() {
    local outfile="$1"
    local prev_q="" prev_cc="" prev_cr=""
    echo "timestamp,questions,qps,com_commit,com_rollback,tps,threads_running,threads_connected" > "$outfile"
    while true; do
        local stats
        stats=$(seekdb_cli -N \
            -e "SHOW GLOBAL STATUS WHERE Variable_name IN ('Questions','Com_commit','Com_rollback','Threads_running','Threads_connected');" 2>/dev/null) \
            || { sleep 1; continue; }
        local q cc cr tr tc
        q=$(echo "$stats"  | awk '/^Questions/ {print $2}')
        cc=$(echo "$stats" | awk '/^Com_commit/ {print $2}')
        cr=$(echo "$stats" | awk '/^Com_rollback/ {print $2}')
        tr=$(echo "$stats" | awk '/^Threads_running/ {print $2}')
        tc=$(echo "$stats" | awk '/^Threads_connected/ {print $2}')
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
    # SeekDB doesn't expose Com_commit / Com_rollback status counters that
    # HammerDB's monitor VU relies on, so HammerDB crashes at rampup-end
    # and never writes a TEST RESULT line. This sampler computes NOPM on
    # our own: every second, snapshot SUM(d_next_o_id) from the district
    # table. A downstream parser picks the rampup-end and run-end samples
    # to compute true NOPM for the measurement window.
    local outfile="$1"
    echo "timestamp,elapsed_sec,sum_next_o_id" > "$outfile"
    local start=$(date +%s)
    while true; do
        local ts elapsed val
        ts=$(date '+%Y-%m-%d %H:%M:%S')
        elapsed=$(( $(date +%s) - start ))
        val=$(seekdb_cli tpcc --init-command="SET SESSION ob_query_timeout=60000000" \
                -N -B -e "SELECT SUM(d_next_o_id) FROM district;" 2>/dev/null | head -1)
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

run_hammerdb() {
    # SeekDB breaks HammerDB's monitor VU (no Com_commit / Com_rollback
    # status counters), so HammerDB never sends the "stop" signal at
    # end-of-duration. Worker VUs happily run until they hit the
    # per-VU 10M-transaction cap (hours). Launch hammerdbcli as a
    # background job, wait exactly rampup+duration, then terminate.
    local outfile="$1"
    local logfile="$2"
    local total_sec=$(( (RAMPUP_MIN + DURATION_MIN) * 60 ))
    # A little slack so HammerDB has time to start up VUs before the
    # countdown begins. Tune if your rampup is very short.
    local startup_slack=20
    log "Running HammerDB (rampup=${RAMPUP_MIN}m duration=${DURATION_MIN}m num_vu=${NUM_VU}, no_stored_procs)"

    (
        cd "$HAMMERDB_DIR"
        HDB_NUM_VU="$NUM_VU" \
        HDB_RAMPUP="$RAMPUP_MIN" \
        HDB_DURATION="$DURATION_MIN" \
        HDB_TC_RATE="$TC_REFRESH_SEC" \
        HDB_OUTFILE="$outfile" \
            ./hammerdbcli auto "$SCRIPT_DIR/hammerdb412_run_seekdb.tcl"
    ) > "$logfile" 2>&1 &
    local hdb_pid=$!
    log "HammerDB pid=$hdb_pid, will run ${total_sec}s then terminate"

    # Wait either for hammerdbcli to exit on its own (unlikely for SeekDB
    # since monitor crashes early) or for our timer to expire.
    local deadline=$(( $(date +%s) + total_sec + startup_slack ))
    while kill -0 "$hdb_pid" 2>/dev/null; do
        if (( $(date +%s) >= deadline )); then
            log "Measurement window over — terminating HammerDB"
            kill -TERM "$hdb_pid" 2>/dev/null || true
            # Also kill any child hammerdbcli process still holding VU threads.
            pkill -TERM -P "$hdb_pid" 2>/dev/null || true
            sleep 3
            # Escalate if still alive.
            kill -KILL "$hdb_pid" 2>/dev/null || true
            pkill -KILL -P "$hdb_pid" 2>/dev/null || true
            break
        fi
        sleep 2
    done
    wait "$hdb_pid" 2>/dev/null || true

    # Sweep up any stragglers that escaped kill -P (worker threads spawned
    # outside the immediate hammerdbcli PID tree).
    pgrep -f "hammerdbcli auto.*hammerdb412_run_seekdb.tcl" \
        | xargs -r kill -TERM 2>/dev/null || true
    sleep 2
    pgrep -f "hammerdbcli auto.*hammerdb412_run_seekdb.tcl" \
        | xargs -r kill -KILL 2>/dev/null || true
    log "HammerDB terminated"
}

write_manifest() {
    local iter_dir="$1" size_gib="$2"
    local manifest="$iter_dir/run.json"
    local ver
    ver=$(seekdb_cli -N -B -e "SELECT VERSION();" 2>/dev/null | head -1)
    local kernel_ver host_ram_gib cpu_governor
    kernel_ver=$(uname -r)
    host_ram_gib=$(awk -v kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)" 'BEGIN{printf "%.2f", kb/1024/1024}')
    cpu_governor=$(cut -d' ' -f1 /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort -u | paste -sd ',' || echo unknown)
    cat > "$manifest" <<JSON
{
  "timestamp_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "benchmark": {
    "tool": "HammerDB",
    "tool_version": "4.12",
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
    "engine": "seekdb",
    "image": "$SEEKDB_IMAGE",
    "version": "${ver:-unknown}",
    "container": "$SEEKDB_CONTAINER",
    "host": "$SEEKDB_HOST",
    "port": $SEEKDB_PORT
  },
  "tuning": {
    "memory_limit_gib": $size_gib
  },
  "paths": {
    "backup_dir": "$BACKUP_DIR",
    "data_dir": "$DATA_DIR",
    "hammerdb_dir": "$HAMMERDB_DIR",
    "hammerdb_run_script": "$SCRIPT_DIR/hammerdb412_run_seekdb.tcl"
  },
  "host": {
    "hostname": "$(hostname)",
    "kernel": "$kernel_ver",
    "cpu_count": $(nproc),
    "ram_gib": $host_ram_gib,
    "cpu_governor": "$cpu_governor"
  }
}
JSON
}

compute_nopm() {
    # Derive NOPM for the measurement window (rampup_end .. run_end) from
    # the nopm_1sec.csv samples. Writes result.txt with NOPM + window.
    local iter_dir="$1" size_gib="$2"
    local csv="$iter_dir/nopm_1sec.csv"
    local out="$iter_dir/result.txt"
    local rampup_sec=$(( RAMPUP_MIN * 60 ))
    local run_end_sec=$(( (RAMPUP_MIN + DURATION_MIN) * 60 ))

    if [[ ! -s "$csv" ]]; then
        echo "no nopm_1sec.csv — cannot compute NOPM" > "$out"
        return
    fi

    # Pick samples closest to rampup-end and run-end elapsed seconds.
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
            printf "MEMORY_LIMIT_GIB=%s\n", sz
            printf "WINDOW_SEC_START=%d\n", best_start_e
            printf "WINDOW_SEC_END=%d\n",   best_end_e
            printf "WINDOW_MINUTES=%.4f\n", mins
            printf "SUM_D_NEXT_O_ID_START=%d\n", best_start_v
            printf "SUM_D_NEXT_O_ID_END=%d\n",   best_end_v
            printf "DELTA_ORDERS=%d\n", delta
            printf "NOPM=%d\n", nopm
        }
    ' "$csv" > "$out"

    # Also emit a per-second NOPM rate series — delta_orders × 60 between
    # consecutive samples. Useful for plotting a throughput timeline.
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

    # Log the headline
    local nopm
    nopm=$(awk -F= '/^NOPM=/ {print $2}' "$out")
    log "Result for ${size_gib}GiB: NOPM=${nopm:-?}"
}

trap 'log "Interrupted"; stop_collectors 2>/dev/null; stop_seekdb; exit 130' INT TERM

# ---------- main sweep ----------

log "Sweep start — results under $RESULTS_ROOT"
log "Sizes (GiB): ${SIZES_GIB[*]}"
log "VU=$NUM_VU rampup=${RAMPUP_MIN}m duration=${DURATION_MIN}m"
log "Backup:  $BACKUP_DIR"
log "Datadir: $DATA_DIR"

for size in "${SIZES_GIB[@]}"; do
    iter_dir="$RESULTS_ROOT/bp-${size}GiB"
    mkdir -p "$iter_dir"
    log "===== Iteration: MEMORY_LIMIT=${size}GiB ($iter_dir) ====="

    stop_seekdb
    restore_datadir
    drop_os_cache
    start_seekdb "$size"
    apply_tuning

    dump_variables     "$iter_dir/seekdb_variables_before.txt"
    dump_tenant_status "$iter_dir/seekdb_status_before.txt"
    dump_system_info   "$iter_dir/system_info.txt"
    write_manifest     "$iter_dir" "$size"

    # Archive stray HammerDB tcount logs before running.
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

    dump_variables     "$iter_dir/seekdb_variables_after.txt"
    dump_tenant_status "$iter_dir/seekdb_status_after.txt"

    # Compute NOPM from our own nopm_1sec.csv. HammerDB's monitor VU
    # crashed at rampup-end (no Com_commit status on SeekDB), so
    # hammerdb_run.out is missing the TEST RESULT line. We use the
    # district.d_next_o_id delta as the authoritative NOPM source.
    compute_nopm "$iter_dir" "$size"

    log "Iteration ${size}GiB complete"
done

stop_seekdb
log "Sweep done — results under $RESULTS_ROOT"
