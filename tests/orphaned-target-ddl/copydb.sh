#! /bin/bash

# A run killed while its CREATE INDEX runs on the target leaves that statement
# running: a backend busy in a statement does not read from its client. When
# it completes, it commits an index that the catalogs never recorded as done.
# pgcopydb sets client_connection_check_interval on its target sessions, so
# the target cancels the statement once the client has closed its connection.
# An index expression holds the CREATE INDEX on an advisory lock the test owns.

set -euo pipefail

export TMPDIR=/tmp/pgcopydb-orphaned-target-ddl
workdir=${TMPDIR}/work
mkdir -p "${TMPDIR}"
clone_args=(--dir "${workdir}" --table-jobs 1 --index-jobs 1 --not-consistent)

# client_connection_check_interval is 10 s
bound=60
clone_pid='' gate_pid=''
free_gate="select pg_terminate_backend(pid) from pg_stat_activity where application_name = 'index_gate'"

cleanup() {
    local status=$?
    trap - EXIT
    test -z "${clone_pid}" || kill -KILL -- "-${clone_pid}" 2>/dev/null || true
    test -z "${gate_pid}" || target_sql "${free_gate}" >/dev/null 2>&1 || true
    if test "${status}" -ne 0; then
        for log in "${TMPDIR}"/*.log; do
            test -f "${log}" || continue
            echo "==> ${log} (tail)"
            tail -n 20 "${log}"
        done
    fi
    exit "${status}"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
equal() { test "$1" = "$2" || fail "$3: expected=$2 actual=$1"; }
source_sql() { timeout 30s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "$1"; }
target_sql() { timeout 30s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "$1"; }

poll() {
    local what=$1 deadline=$((SECONDS + 120)) rc=''
    shift
    until "$@"; do
        if test -n "${clone_pid}" && ! kill -0 "${clone_pid}" 2>/dev/null; then
            wait "${clone_pid}" || rc=$?
            clone_pid=
            fail "pgcopydb exited ${rc:-0} while waiting for ${what}"
        fi
        test "${SECONDS}" -lt "${deadline}" || fail "timed out waiting for ${what}"
        sleep 0.2
    done
}

gate_held() {
    test "$(target_sql "select count(*) from pg_locks where locktype = 'advisory' and objid = 42 and granted and mode = 'ExclusiveLock'")" = 1
}

index_blocked() {
    test "$(target_sql "select count(*) from pg_stat_activity a join pg_locks l on l.pid = a.pid
        where a.query like 'CREATE INDEX%gated_idx%' and l.locktype = 'advisory' and l.objid = 42 and not l.granted")" = 1
}

backend_gone() {
    test "$(target_sql "select count(*) from pg_stat_activity where pid = ${index_pid}")" = 0
}

own_group() {
    test "$(ps -o pgid= -p "${clone_pid}" | tr -d ' ')" = "${clone_pid}"
}

pgcopydb ping

source_sql "drop table if exists gated;
    drop function if exists index_gate(integer);
    create function index_gate(integer) returns integer immutable language plpgsql
        as \$\$ begin perform pg_advisory_xact_lock_shared(42); return \$1; end \$\$;
    create table gated(id integer primary key);
    insert into gated select generate_series(1, 1000);
    create index gated_idx on gated (index_gate(id))"

PGAPPNAME=index_gate psql -AtqX -d "${PGCOPYDB_TARGET_PGURI}" \
    -c 'select pg_advisory_lock(42)' -c 'select pg_sleep(600)' >"${TMPDIR}/gate.out" 2>&1 &
gate_pid=$!
poll 'the index gate to close' gate_held

setsid pgcopydb clone "${clone_args[@]}" >"${TMPDIR}/clone.log" 2>&1 &
clone_pid=$!
poll 'pgcopydb to own its process group' own_group
poll 'the CREATE INDEX of gated_idx to wait on the gate' index_blocked
index_pid=$(target_sql "select pid from pg_stat_activity where query like 'CREATE INDEX%gated_idx%'")
[[ ${index_pid} =~ ^[0-9]+$ ]] || fail "the CREATE INDEX backend pid is '${index_pid}'"

kill -KILL -- "-${clone_pid}"
wait "${clone_pid}" || true
clone_pid=

start=${SECONDS}
until backend_gone; do
    test $((SECONDS - start)) -lt "${bound}" ||
        fail "the CREATE INDEX backend ${index_pid} of the killed run still runs after ${bound} s"
    sleep 0.5
done
echo "the target ended the CREATE INDEX of the killed run in $((SECONDS - start)) s"

target_sql "${free_gate}" >/dev/null
wait "${gate_pid}" || true
gate_pid=

equal "$(target_sql "select to_regclass('public.gated_idx') is null")" t 'gated_idx is absent on the target'
echo 'PASS: the target cancels the statement of a killed run'
