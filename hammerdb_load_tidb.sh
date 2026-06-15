#!/bin/bash
# Load TPC-C data into TiDB using HammerDB 5.0.
# TiDB must already be running and accepting MySQL-protocol connections on
# port 4000 (start it with start_tidb.sh or sweep_tidb.sh).
#
# Prerequisites:
#   - TiDB cluster running on 127.0.0.1:4000 (tiup playground or equivalent)
#   - HammerDB 5.0 at /opt/HammerDB-5.0 (override with HAMMERDB_DIR)
#   - Enough disk space: 1000 warehouses ≈ 100 GiB on TiKV
#
# Run via:
#   ./hammerdb_load_tidb.sh
#   HAMMERDB_DIR=/opt/HammerDB-5.0 ./hammerdb_load_tidb.sh

set -euo pipefail

HAMMERDB_VERSION="5.0"
HAMMERDB_DIR="${HAMMERDB_DIR:-/opt/HammerDB-${HAMMERDB_VERSION}}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -x "${HAMMERDB_DIR}/hammerdbcli" ]]; then
    echo "HammerDB ${HAMMERDB_VERSION} not found at ${HAMMERDB_DIR}"
    echo "Download: https://github.com/TPC-Council/HammerDB/releases/tag/v${HAMMERDB_VERSION}"
    echo "  curl -L -o /tmp/hammerdb.tar.gz https://github.com/TPC-Council/HammerDB/releases/download/v${HAMMERDB_VERSION}/HammerDB-${HAMMERDB_VERSION}-Linux.tar.gz"
    echo "  tar -xzf /tmp/hammerdb.tar.gz -C /opt/"
    exit 1
fi

echo "Loading TPC-C schema into TiDB on 127.0.0.1:4000 ..."
cd "${HAMMERDB_DIR}"
./hammerdbcli auto "${SCRIPT_DIR}/hammerdb_load_tidb.tcl"
echo "Load complete."
