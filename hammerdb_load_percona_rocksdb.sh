#!/bin/bash
# Load TPC-C data into Percona Server MyRocks via HammerDB 5.0.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HAMMERDB_DIR="${HAMMERDB_DIR:-/opt/HammerDB-5.0}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-rootpassword}"
LOAD_TCL="$SCRIPT_DIR/hammerdb_load_percona_rocksdb.tcl"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; exit 1; }

[[ -x "$HAMMERDB_DIR/hammerdbcli" ]] || die "HammerDB not found at $HAMMERDB_DIR"
[[ -f "$LOAD_TCL" ]]                 || die "Missing $LOAD_TCL"

log "Probing Percona MyRocks at 127.0.0.1:3306"
mysql -h 127.0.0.1 -P 3306 -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B \
    -e "SHOW ENGINES;" \
    | awk '$1 == "ROCKSDB" && $2 == "YES" {found=1} END {exit found ? 0 : 1}' \
    || die "ROCKSDB engine is not available at 127.0.0.1:3306"

log "Dropping any existing tpcc database"
mysql -h 127.0.0.1 -P 3306 -uroot -p"$MYSQL_ROOT_PASSWORD" \
    -e "DROP DATABASE IF EXISTS tpcc;"

log "Running HammerDB build (engine=ROCKSDB warehouses=${HDB_WAREHOUSES:-1000} load_vu=${HDB_LOAD_VU:-64})"
cd "$HAMMERDB_DIR"
HDB_MYSQL_PASS="$MYSQL_ROOT_PASSWORD" ./hammerdbcli auto "$LOAD_TCL"

log "Verifying TPC-C table engines"
mysql -h 127.0.0.1 -P 3306 -uroot -p"$MYSQL_ROOT_PASSWORD" tpcc \
    -e "SELECT TABLE_NAME, ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA='tpcc' ORDER BY TABLE_NAME;"

log "Load complete. Snapshot the datadir before sweeping, for example:"
log "  rsync -a --delete /data/rocksdb/ /backup/rocksdb/"
