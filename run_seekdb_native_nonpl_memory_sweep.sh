#!/bin/bash
# Run a native/RPM SeekDB HammerDB TPC-C memory_limit sweep in non-PL mode.
# This wrapper only sets runtime options; the benchmark logic remains in
# sweep_seekdb.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

export HAMMERDB_DIR="${HAMMERDB_DIR:-/opt/hammerdb}"
export SEEKDB_MODE="${SEEKDB_MODE:-native}"
export SEEKDB_SERVICE="${SEEKDB_SERVICE:-seekdb}"
export SEEKDB_CNF="${SEEKDB_CNF:-/etc/seekdb/seekdb.cnf}"
export SEEKDB_HOST="${SEEKDB_HOST:-127.0.0.1}"
export SEEKDB_PORT="${SEEKDB_PORT:-2881}"
export SEEKDB_USER="${SEEKDB_USER:-root}"
export SEEKDB_PASS="${SEEKDB_PASS:-password}"

export BACKUP_DIR="${BACKUP_DIR:-/data/1/sbackup}"
export DATA_DIR="${DATA_DIR:-/data/1/sdata}"

export SWEEP_SIZES_GIB="${SWEEP_SIZES_GIB:-10 30 50 70 90 110}"
export LOG_DISK_SIZE_MULTIPLIER="${LOG_DISK_SIZE_MULTIPLIER:-3}"
export RAMPUP_MIN="${RAMPUP_MIN:-2}"
export DURATION_MIN="${DURATION_MIN:-10}"
export NUM_VU="${NUM_VU:-200}"
export TC_REFRESH_SEC="${TC_REFRESH_SEC:-1}"

cd "$SCRIPT_DIR"
exec ./sweep_seekdb.sh
