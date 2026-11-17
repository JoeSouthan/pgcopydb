#! /bin/bash

# A transaction the apply did not commit must not move the replication origin:
# PostgreSQL 16 and later move it on an abort after the origin setup.
# Case B makes the COMMIT fail in a deferred trigger only the target has.
# Case C terminates the target backend while such a trigger runs at COMMIT.
# Case D makes the COMMIT statement itself fail once the setup has run.
# Each case then resumes and expects the transaction applied, none skipped.
#
# Cases B and C are from Yannick Dixken's cdc-origin-abort suite.

set -euxo pipefail

TMPDIR=$(mktemp -d /tmp/pgcopydb-origin-abort.XXXXXX)
export TMPDIR
export XDG_DATA_HOME=${TMPDIR}/cdc
snapshot_pid= apply_pid= failures=0

cleanup() {
    local status=$?
    trap - EXIT
    if test "${status}" -ne 0; then
        for log in "${TMPDIR}"/*.log; do
            test ! -f "${log}" || cat "${log}"
        done
    fi
    for pid in "${apply_pid}" "${snapshot_pid}"; do
        test -z "${pid}" || kill -TERM "${pid}" 2>/dev/null || true
    done
    exit "${status}"
}
trap cleanup EXIT

source_sql() { timeout 15s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "$1"; }
target_sql() { timeout 15s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "$1"; }
origin() { target_sql "select pg_replication_origin_progress('pgcopydb', false)"; }
digest() { echo "select count(*), md5(string_agg(row(id, k, v)::text, ',' order by id)) from oa where $1"; }

# commit_lsn <xid>: the COMMIT LSN receive spooled for that transaction
commit_lsn() {
    local file lsn
    for file in "${XDG_DATA_HOME}/pgcopydb"/*-output.db; do
        lsn=$(sqlite3 -readonly -init /dev/null -batch -noheader -list "${file}" \
            "select printf('%X/%X', lsn >> 32, lsn & 4294967295) from output where xid = $1 and action = 'C'")
        if test -n "${lsn}"; then echo "${lsn}"; return; fi
    done
    echo "FAIL: no COMMIT spooled for xid $1" >&2
    return 1
}

# spool <sql>: run a transaction on the source and spool it, prints its COMMIT LSN
spool() {
    local xid
    xid=$(source_sql "begin; select pg_current_xact_id(); $1; commit")
    timeout 60s pgcopydb stream prefetch --resume --endpos "$(source_sql 'select pg_current_wal_flush_lsn()')" >&2
    commit_lsn "${xid}"
}

check() {
    if test "$2" = "$3"; then
        echo "OK   $1: $3"
    else
        echo "FAIL $1: expected $2, got $3"
        failures=$((failures + 1))
    fi
}

pgcopydb ping
source_sql 'drop table if exists oa; create table oa (id integer primary key, k integer, v text)'
source_sql "insert into oa select i, i, md5(i::text) from generate_series(1, 10) i"
target_sql 'drop table if exists oa'
pgcopydb snapshot --follow --plugin pgoutput >"${TMPDIR}/snapshot.out" &
snapshot_pid=$!
deadline=$((SECONDS + 60))
while ! test -s "${TMPDIR}/snapshot.out"; do
    kill -0 "${snapshot_pid}"
    test "${SECONDS}" -lt "${deadline}"
    sleep 0.1
done
pgcopydb stream setup
pgcopydb clone --drop-if-exists
kill -TERM "${snapshot_pid}"
wait "${snapshot_pid}" || true
snapshot_pid=
pgcopydb stream sentinel set apply

#
# Case B: the COMMIT fails, the conflict is removed, and the apply resumes
#
# A deferred unique constraint would not do: session_replication_role = replica
# skips its recheck trigger. An ALWAYS constraint trigger still fires at COMMIT.
target_sql "create function oa_reject() returns trigger language plpgsql as \$\$
    begin raise exception 'oa_reject refuses row %', new.id; end \$\$;
    create constraint trigger oa_reject after insert on oa deferrable initially deferred
    for each row when (new.v = 'dup') execute function oa_reject();
    alter table oa enable always trigger oa_reject"
commit_b1=$(spool "insert into oa values (1001, 1, 'dup')")
commit_b2=$(spool "insert into oa values (1002, 1002, 'after')")
pgcopydb stream sentinel set endpos "${commit_b2}"
origin_before=$(origin)

status=0
timeout 60s pgcopydb stream catchup --resume --endpos "${commit_b2}" >"${TMPDIR}/fail.log" 2>&1 || status=$?
grep -E 'ERROR|FATAL' "${TMPDIR}/fail.log" | cut -c1-300 || true
test "${status}" -ne 0
grep -q 'oa_reject refuses row 1001' "${TMPDIR}/fail.log"
check "B: origin after failed COMMIT at ${commit_b1}" "${origin_before}" "$(origin)"

target_sql 'drop trigger oa_reject on oa'
timeout 60s pgcopydb stream catchup --resume --endpos "${commit_b2}"
check "B: origin after resume" "${commit_b2}" "$(origin)"
check "B: rows after resume" "$(source_sql "$(digest 'id > 1000')")" "$(target_sql "$(digest 'id > 1000')")"

#
# Case C: the target backend is terminated while a deferred trigger runs
#
target_sql "create function oa_stall() returns trigger language plpgsql as \$\$
    begin perform pg_sleep(300); return null; end \$\$;
    create constraint trigger oa_stall after insert on oa deferrable initially deferred
    for each row when (new.v = 'stall') execute function oa_stall();
    alter table oa enable always trigger oa_stall"
commit_c=$(spool "insert into oa values (2001, 1, 'stall')")
pgcopydb stream sentinel set endpos "${commit_c}"
origin_before=$(origin)

timeout 120s pgcopydb stream catchup --resume --endpos "${commit_c}" >"${TMPDIR}/stall.log" 2>&1 &
apply_pid=$!
deadline=$((SECONDS + 60))
while true; do
    stalled=$(target_sql "select pid from pg_stat_activity
     where application_name like 'pgcopydb%' and wait_event = 'PgSleep'")
    if [[ ${stalled} =~ ^[1-9][0-9]*$ ]]; then break; fi
    kill -0 "${apply_pid}"
    test "${SECONDS}" -lt "${deadline}"
    sleep 0.1
done
target_sql "select state, query from pg_stat_activity where pid = ${stalled}"
target_sql "select pg_terminate_backend(${stalled}, 10000)"
status=0
wait "${apply_pid}" || status=$?
apply_pid=
grep -E 'ERROR|FATAL' "${TMPDIR}/stall.log" | cut -c1-300 || true
test "${status}" -ne 0
check "C: origin after termination at ${commit_c}" "${origin_before}" "$(origin)"

target_sql 'drop trigger oa_stall on oa'
timeout 60s pgcopydb stream catchup --resume --endpos "${commit_c}"
check "C: origin after resume" "${commit_c}" "$(origin)"
check "C: rows after resume" "$(source_sql "$(digest 'id > 2000')")" "$(target_sql "$(digest 'id > 2000')")"

#
# Case D: the COMMIT statement fails after the origin setup has run
#
commit_d1=$(spool "insert into oa values (3001, 3001, 'kept')")
commit_d2=$(spool "insert into oa values (3002, 3002, 'failed')")
pgcopydb stream sentinel set endpos "${commit_d2}"

timeout 120s gdb -q -batch \
    -ex "set \$expected_lsn = \"${commit_d2}\"" \
    -x /usr/src/pgcopydb/fail-commit.gdb \
    --args pgcopydb stream catchup --resume --endpos "${commit_d2}" >"${TMPDIR}/gdb.log" 2>&1
grep -E 'XOMMIT|ERROR|FATAL|WARN' "${TMPDIR}/gdb.log" | cut -c1-300 || true
check "D: origin after failed COMMIT at ${commit_d2}" "${commit_d1}" "$(origin)"
check "D: rows committed before the failure" "1" "$(target_sql 'select count(*) from oa where id = 3001')"

timeout 60s pgcopydb stream catchup --resume --endpos "${commit_d2}"
check "D: origin after resume" "${commit_d2}" "$(origin)"
check "D: rows after resume" "$(source_sql "$(digest 'id > 3000')")" "$(target_sql "$(digest 'id > 3000')")"

pgcopydb stream cleanup
echo "RESULT failures=${failures}"
test "${failures}" -eq 0
