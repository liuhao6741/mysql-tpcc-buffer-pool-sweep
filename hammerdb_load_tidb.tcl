#!/usr/bin/tclsh
# HammerDB 5.0 TPC-C schema build for TiDB (MySQL wire protocol on port 4000).
#
# TiDB does not support CREATE PROCEDURE bodies that HammerDB emits for MySQL;
# `mysql_no_stored_procs true` tells the *run-time driver* to embed SQL inline
# instead of CALL. HammerDB still attempts to create the procs during build,
# so errors there are expected and non-fatal for the data load.
#
# TiDB also lacks full partitioning support in the shape HammerDB expects —
# keep `mysql_partition false` so the schema is minimal.
#
# Run via:
#   /opt/HammerDB-5.0/hammerdbcli auto /root/benchmarks/hammerdb_load_tidb.tcl

puts "SETTING CONFIGURATION (tidb build)"
dbset db mysql
dbset bm TPC-C

# TiDB defaults: MySQL-protocol wire on port 4000, no password for root.
diset connection mysql_host 127.0.0.1
diset connection mysql_port 4000
diset connection mysql_socket null
diset connection mysql_ssl false

diset tpcc mysql_user root
diset tpcc mysql_pass rootpassword
diset tpcc mysql_dbase tpcc
diset tpcc mysql_storage_engine innodb


# No partitioning — TiDB's hash/range partitioning differs from MySQL's.
diset tpcc mysql_partition false
diset tpcc mysql_history_pk true

# Scale: 1000 warehouses to match other profiles.
diset tpcc mysql_count_ware 1000
# 16 loader VUs — fewer concurrent writers keep TiKV's RocksDB memtable
# pressure manageable during the multi-hour bulk load. Higher counts can
# trigger write-stalls under limited block-cache / memory budgets.
diset tpcc mysql_num_vu 64

puts "SCHEMA BUILD STARTED"
set ret [buildschema]
puts "SCHEMA BUILD COMPLETED: $ret"
