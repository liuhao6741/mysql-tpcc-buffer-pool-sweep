#!/bin/bash
set -euo pipefail

# Override MEMORY_LIMIT for buffer-pool-style sweeps.
MEMORY_LIMIT="${MEMORY_LIMIT:-110G}"

mkdir -p /data/seekdb

docker run -d \
  --name seekdb \
  --restart unless-stopped \
  -e MEMORY_LIMIT="$MEMORY_LIMIT" \
  -e LOG_DISK_SIZE=32G \
  -e CPU_COUNT=0 \
  -e DATAFILE_MAXSIZE=512G \
  -e ROOT_PASSWORD=password \
  -e SEEKDB_DATABASE=sbtest \
  -v /data/seekdb:/var/lib/oceanbase \
  --network host \
  quay.io/oceanbase/seekdb:latest

# Wait for SeekDB to accept MySQL-protocol connections on 2881.
# The container entrypoint bootstraps the data dir on first run; that can
# take several minutes before the SQL port is ready.
echo "Waiting for SeekDB to accept connections on 127.0.0.1:2881..."
for i in {1..300}; do
    if mysql -h 127.0.0.1 -P 2881 -uroot -ppassword \
             -e "SELECT 1" >/dev/null 2>&1; then
        echo "SeekDB ready after ${i}s"
        break
    fi
    sleep 1
done

# Apply tuning + pre-benchmark settings. Each statement is idempotent, so
# re-running start_seekdb.sh on an existing volume is safe.
echo "Applying SeekDB tuning (defensive checks off, freeze / throttle tweaks, long query timeout)..."
mysql -h 127.0.0.1 -P 2881 -uroot -ppassword <<'SQL'
-- Disable defensive checks (reduces extra validation overhead)
ALTER SYSTEM SET _enable_defensive_check = FALSE;

-- Eliminate LCL operation interval limits
ALTER SYSTEM SET _lcl_op_interval = '0ms';

-- Lower log level (reduces log write I/O)
ALTER SYSTEM SET syslog_level = 'ERROR';

-- Disable micro-block merge verification (reduces compaction CPU overhead)
ALTER SYSTEM SET micro_block_merge_verify_level = 0;

-- Disable SQL trace (reduces internal tracing overhead)
CALL DBMS_MONITOR.OB_TENANT_TRACE_DISABLE;

-- Only throttle writes at 100% memory (no premature throttling)
ALTER SYSTEM SET writing_throttling_trigger_percentage = 100;

-- Freeze trigger threshold (controls memtable flush timing)
ALTER SYSTEM SET freeze_trigger_percentage = 70;

-- Enable user-defined rewrite rules
ALTER SYSTEM SET enable_user_defined_rewrite_rules = TRUE;

-- Long query timeout so bulk loaders / long scans don't get killed
SET GLOBAL ob_query_timeout = 3600000000;
SQL

echo "SeekDB tuning applied."
