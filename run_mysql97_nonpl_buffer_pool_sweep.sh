#!/bin/bash
# Run a MySQL 9.7 HammerDB TPC-C buffer pool sweep in non-PL mode.
# This wrapper only sets runtime options; the benchmark logic remains in
# sweep_buffer_pool.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# MySQL 9.7 uses caching_sha2_password. sweep_buffer_pool.sh primes the auth
# cache with a TLS login before running HammerDB over plain TCP. The host mysql
# client on this machine is MariaDB and does not support --ssl-mode, so provide
# a temporary wrapper that runs the MySQL client inside the mysql97 container.
BENCH_BIN="${BENCH_BIN:-/tmp/bench-bin}"
mkdir -p "$BENCH_BIN"
cat > "$BENCH_BIN/mysql" <<'MYSQL_WRAPPER'
#!/bin/bash
args=()
for arg in "$@"; do
  case "$arg" in
    --ssl-ca=/data/1/data/ca.pem)
      args+=("--ssl-ca=/var/lib/mysql/ca.pem")
      ;;
    *)
      args+=("$arg")
      ;;
  esac
done
exec docker exec mysql97 mysql "${args[@]}"
MYSQL_WRAPPER
chmod +x "$BENCH_BIN/mysql"

export PATH="$BENCH_BIN:$PATH"
export HAMMERDB_DIR="${HAMMERDB_DIR:-/opt/hammerdb}"
export MYSQL_PROFILE="${MYSQL_PROFILE:-9.7}"
export MYSQL_IMAGE="${MYSQL_IMAGE:-mysql:9.7.0-lts}"
export CONTAINER="${CONTAINER:-mysql97}"
export BACKUP_DIR="${BACKUP_DIR:-/data/1/pbackup}"
export DATA_DIR="${DATA_DIR:-/data/1/data}"

export SWEEP_SIZES_GIB="${SWEEP_SIZES_GIB:-10 30 50 70 90 110}"
export RAMPUP_MIN="${RAMPUP_MIN:-10}"
export DURATION_MIN="${DURATION_MIN:-60}"
export HDB_SSL="${HDB_SSL:-false}"
export HDB_NO_STORED_PROCS="${HDB_NO_STORED_PROCS:-true}"

cd "$SCRIPT_DIR"
exec ./sweep_buffer_pool.sh
