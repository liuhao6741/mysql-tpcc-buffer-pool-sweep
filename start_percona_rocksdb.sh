#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PERCONA_CONTAINER="${PERCONA_CONTAINER:-percona-rocksdb}"
PERCONA_IMAGE="${PERCONA_IMAGE:-percona/percona-server:8.0}"
DATA_DIR="${DATA_DIR:-/data/rocksdb}"
CNF="${CNF:-$SCRIPT_DIR/percona_rocksdb.cnf}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-rootpassword}"

# Percona's official image has used uid 1001 in recent releases. Override this
# if `docker run --rm percona/percona-server:8.0 id mysql` says otherwise.
PERCONA_DATA_UID="${PERCONA_DATA_UID:-1001}"

mkdir -p "$DATA_DIR"
chown -R "${PERCONA_DATA_UID}:${PERCONA_DATA_UID}" "$DATA_DIR" 2>/dev/null || chmod 777 "$DATA_DIR"

docker rm -f "$PERCONA_CONTAINER" >/dev/null 2>&1 || true

docker run -d \
  --name "$PERCONA_CONTAINER" \
  --restart unless-stopped \
  -e MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD" \
  -e MYSQL_ROOT_HOST=% \
  -v "$DATA_DIR":/var/lib/mysql \
  -v "$CNF":/etc/my.cnf:ro \
  --network host \
  "$PERCONA_IMAGE"

echo "Waiting for Percona Server / MyRocks to become ready..."
ready=0
for i in {1..180}; do
  status=$(docker inspect -f '{{.State.Status}}' "$PERCONA_CONTAINER" 2>/dev/null || echo missing)
  if [[ "$status" == "exited" || "$status" == "dead" ]]; then
    docker logs --tail 80 "$PERCONA_CONTAINER" 2>&1 | sed 's/^/  /' >&2
    echo "Percona container exited during startup (status=$status)" >&2
    exit 1
  fi
  if docker exec "$PERCONA_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" \
      -N -B -e "SELECT 1;" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done

if [[ "$ready" != "1" ]]; then
  docker logs --tail 80 "$PERCONA_CONTAINER" 2>&1 | sed 's/^/  /' >&2
  echo "Percona Server did not become ready with the configured root password." >&2
  echo "If $DATA_DIR already existed, MYSQL_ROOT_PASSWORD is ignored by the image entrypoint." >&2
  exit 1
fi

docker exec -i "$PERCONA_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<SQL >/dev/null
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED WITH mysql_native_password BY '$MYSQL_ROOT_PASSWORD';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY '$MYSQL_ROOT_PASSWORD';
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$MYSQL_ROOT_PASSWORD';
FLUSH PRIVILEGES;
SQL

docker exec -i "$PERCONA_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<'SQL' >/dev/null 2>&1 || true
INSTALL PLUGIN ROCKSDB SONAME 'ha_rocksdb.so';
SQL

docker exec "$PERCONA_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" \
  -N -B -e "SHOW ENGINES;" \
  | awk '$1 == "ROCKSDB" && $2 == "YES" {found=1} END {exit found ? 0 : 1}' \
  || { echo "ROCKSDB engine is not available" >&2; exit 1; }

docker exec "$PERCONA_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" \
  -e "SHOW ENGINES; SHOW VARIABLES LIKE 'rocksdb_block_cache_size';" \
  | sed -n '/ROCKSDB/p;/rocksdb_block_cache_size/p'

echo "Percona MyRocks ready."
