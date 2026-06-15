#!/usr/bin/tclsh
# HammerDB 5.0 TPC-C timed run for TiDB (MySQL wire protocol on port 4000).
#
# Important: mysql_no_stored_procs=true — the TiDB schema is loaded without
# TPC-C stored procedures, so the run-time driver must embed SQL inline
# instead of issuing CALL NEWORD / CALL PAYMENT / etc.
#
# TiDB exposes Com_commit / Com_rollback via SHOW GLOBAL STATUS (MySQL
# compatibility layer), so HammerDB's monitor VU SHOULD survive rampup-end
# and emit a TEST RESULT line. If it doesn't (e.g. TiDB version skew),
# the sweep script includes a fallback external NOPM sampler.
#
# Env overrides (same names as mysql/maria/seekdb variants):
#   HDB_NUM_VU     number of virtual users (default: 80)
#   HDB_RAMPUP     rampup minutes            (default: 10)
#   HDB_DURATION   measurement minutes       (default: 60)
#   HDB_TC_RATE    tx counter refresh (sec)  (default: 1)
#   HDB_OUTFILE    result summary path       (default: /tmp/hammerdb_run.out)

set num_vu   [expr {[info exists ::env(HDB_NUM_VU)]   ? $::env(HDB_NUM_VU)   : 80}]
set rampup   [expr {[info exists ::env(HDB_RAMPUP)]   ? $::env(HDB_RAMPUP)   : 10}]
set duration [expr {[info exists ::env(HDB_DURATION)] ? $::env(HDB_DURATION) : 60}]
set tc_rate  [expr {[info exists ::env(HDB_TC_RATE)]  ? $::env(HDB_TC_RATE)  : 1}]
set outfile  [expr {[info exists ::env(HDB_OUTFILE)]  ? $::env(HDB_OUTFILE)  : "/tmp/hammerdb_run.out"}]

puts "SETTING CONFIGURATION (tidb num_vu=$num_vu rampup=${rampup}m duration=${duration}m tc_rate=${tc_rate}s)"
dbset db mysql
dbset bm TPC-C

diset connection mysql_host 127.0.0.1
diset connection mysql_port 4000
diset connection mysql_socket null
diset connection mysql_ssl false

diset tpcc mysql_user root
diset tpcc mysql_pass rootpassword
diset tpcc mysql_dbase tpcc
diset tpcc mysql_driver timed
diset tpcc mysql_rampup $rampup
diset tpcc mysql_duration $duration
diset tpcc mysql_allwarehouse true
diset tpcc mysql_timeprofile false
diset tpcc mysql_num_vu $num_vu
# TiDB schema was loaded without stored procedures. Driver must inline the
# SQL instead of CALLing procs that don't exist.
diset tpcc mysql_no_stored_procs true

tcset refreshrate $tc_rate
tcset logtotemp 1
tcset unique 1
tcset timestamps 1

loadscript
puts "TEST STARTED"
vuset vu $num_vu
vucreate
tcstart
tcstatus
set vurun_ret [vurun]
vudestroy
tcstop
if {[regexp {jobid=([0-9A-Fa-f]+)} $vurun_ret -> jobid]} {
    puts "TEST COMPLETE jobid=$jobid"
} else {
    set jobid ""
    puts "TEST COMPLETE — could not parse jobid from: $vurun_ret"
}

set fh [open $outfile w]
puts $fh "jobid=$jobid"
puts $fh "num_vu=$num_vu"
puts $fh "rampup_min=$rampup"
puts $fh "duration_min=$duration"
puts $fh "tc_refresh_sec=$tc_rate"
puts $fh "---"
if {$jobid ne ""} {
    puts $fh "TRANSACTION RESPONSE TIMES"
    if {[catch {job $jobid timing} res]} { puts $fh "ERROR: $res" } else { puts $fh $res }
    puts $fh "TRANSACTION COUNT"
    if {[catch {job $jobid tcount} res]} { puts $fh "ERROR: $res" } else { puts $fh $res }
    puts $fh "HAMMERDB RESULT"
    if {[catch {job $jobid result} res]} { puts $fh "ERROR: $res" } else { puts $fh $res }
} else {
    puts $fh "no jobid — vurun returned: $vurun_ret"
}
close $fh
puts "RESULTS WRITTEN TO $outfile"
