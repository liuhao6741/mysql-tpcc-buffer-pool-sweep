#!/bin/bash
# Load TPC-C data into SeekDB via HammerDB 5.0.
#
# Assumes a SeekDB container is already running and reachable at
# 127.0.0.1:2881 with root/password. Unlike the MySQL/MariaDB load
# wrappers, this one does NOT manage the container — SeekDB's startup
# is orchestrated outside this script.
#
# The load will attempt to create stored procedures and is expected to
# emit errors for them (SeekDB doesn't support the CREATE PROCEDURE
# bodies HammerDB emits). The run-time driver uses `mysql_no_stored_procs
# true` so measurement works without the procs — the load itself
# (tables + data rows + statistics) is what this wrapper cares about.
#
# Usage:
#   ./hammerdb_load_seekdb.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HAMMERDB_DIR="${HAMMERDB_DIR:-/opt/HammerDB-5.0}"
LOAD_TCL="$SCRIPT_DIR/hammerdb_load_seekdb.tcl"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; exit 1; }

[[ -x "$HAMMERDB_DIR/hammerdbcli" ]] || die "HammerDB not found at $HAMMERDB_DIR"
[[ -f "$LOAD_TCL" ]]                 || die "Missing $LOAD_TCL"

run_sql() {
    mysql -h 127.0.0.1 -P 2881 -uroot -ppassword "$@"
}

wait_for_major_compaction() {
    local timeout_sec="${MAJOR_FREEZE_TIMEOUT_SEC:-1800}"
    local poll_sec="${MAJOR_FREEZE_POLL_SEC:-10}"
    local deadline=$(( $(date +%s) + timeout_sec ))
    local status=""

    log "Triggering major compaction"
    run_sql -e "ALTER SYSTEM MAJOR FREEZE;"

    log "Waiting for major compaction to become IDLE (timeout=${timeout_sec}s, poll=${poll_sec}s)"
    while true; do
        status=$(run_sql -N -B -e "SELECT STATUS FROM oceanbase.DBA_OB_MAJOR_COMPACTION;" 2>/dev/null | tail -1)
        if [[ "$status" == "IDLE" ]]; then
            log "Major compaction completed: STATUS=${status}"
            return 0
        fi

        if (( $(date +%s) >= deadline )); then
            die "major compaction did not become IDLE before timeout (last STATUS='${status:-unknown}')"
        fi

        log "Major compaction status: ${status:-unknown}; sleeping ${poll_sec}s"
        sleep "$poll_sec"
    done
}

log "Probing SeekDB at 127.0.0.1:2881"
run_sql -e "SELECT VERSION();" >/dev/null 2>&1 \
    || die "SeekDB not reachable at 127.0.0.1:2881 (root/password)"

log "Dropping any existing tpcc database"
run_sql -e "DROP DATABASE IF EXISTS tpcc;" 2>/dev/null || true

log "Running HammerDB build (1000 warehouses, 64 loader VUs, no stored procs)"
cd "$HAMMERDB_DIR"
./hammerdbcli auto "$LOAD_TCL"

wait_for_major_compaction

log "Verifying table row counts (long ob_query_timeout so COUNT(*) on 100M-row tables finishes)"
for t in warehouse district item customer stock orders new_order order_line history; do
    n=$(run_sql tpcc \
            --init-command="SET SESSION ob_query_timeout=600000000" \
            -N -B -e "SELECT COUNT(*) FROM $t;" 2>/dev/null | tail -1)
    printf "  %-12s %s\n" "$t" "${n:-ERROR}"
done

log "Load complete"
