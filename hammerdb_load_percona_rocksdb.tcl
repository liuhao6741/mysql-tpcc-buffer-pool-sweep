#!/usr/bin/tclsh
# HammerDB 5.0 TPC-C schema build for Percona Server MyRocks.
#
# The important differences from the InnoDB loader:
#   - mysql_storage_engine is ROCKSDB.
#   - mysql_partition is false to keep the schema simple and portable.
#   - The server config sets READ-COMMITTED, matching MyRocks' constraints for
#     SELECT ... FOR UPDATE in this workload.

puts "SETTING CONFIGURATION (percona myrocks build)"
dbset db mysql
dbset bm TPC-C

diset connection mysql_host 127.0.0.1
diset connection mysql_port 3306
diset connection mysql_socket null
diset connection mysql_ssl false

set warehouses [expr {[info exists ::env(HDB_WAREHOUSES)] ? $::env(HDB_WAREHOUSES) : 1000}]
set load_vu    [expr {[info exists ::env(HDB_LOAD_VU)]    ? $::env(HDB_LOAD_VU)    : 64}]
set mysql_pass [expr {[info exists ::env(HDB_MYSQL_PASS)] ? $::env(HDB_MYSQL_PASS) : "rootpassword"}]

diset tpcc mysql_user root
diset tpcc mysql_pass $mysql_pass
diset tpcc mysql_dbase tpcc
diset tpcc mysql_storage_engine rocksdb
diset tpcc mysql_partition false
diset tpcc mysql_count_ware $warehouses
diset tpcc mysql_num_vu $load_vu

puts "SCHEMA BUILD STARTED (warehouses=$warehouses load_vu=$load_vu engine=ROCKSDB)"
set ret [buildschema]
puts "SCHEMA BUILD COMPLETED: $ret"
