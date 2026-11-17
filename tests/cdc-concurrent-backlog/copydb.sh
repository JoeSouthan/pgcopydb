#! /bin/bash

# Live apply catching up on a backlog of concurrent, overlapping transactions.
#
# Receive spools rounds of writes from several clients while apply is not
# running, as it is during a long initial copy, rotating to a new output.db
# after every COMMIT. Between rounds the test waits for receive to spool a
# KEEPALIVE, which then opens the file of the next round's first transaction,
# as it does when the walsender sends only keepalives for a while (for example
# while it decodes a large transaction). Apply then catches up with no endpos,
# over files that receive has already closed. Each client runs multi-statement
# transactions that overlap the other clients', and a queue table is inserted
# into and deleted from on a unique key, so a transaction that is skipped
# either leaves rows missing or fails a later insert.
#
# Every row on the source must reach the target.

set -euo pipefail

clients=${CLIENTS:-8}
rounds=${ROUNDS:-6}
txns=${TXNS_PER_CLIENT_PER_ROUND:-5}
export TMPDIR=/tmp/pgcopydb-concurrent-backlog
export XDG_DATA_HOME=${TMPDIR}/cdc
mkdir -p "${TMPDIR}"
snapshot_pid='' prefetch_pid='' catchup_pid=''
load_pids=()

cleanup() {
    local status=$?
    trap - EXIT
    for pid in "${load_pids[@]}"; do kill "${pid}" 2>/dev/null || true; done
    test -z "${catchup_pid}" || kill -KILL -- "-${catchup_pid}" 2>/dev/null || true
    test -z "${prefetch_pid}" || kill -KILL -- "-${prefetch_pid}" 2>/dev/null || true
    test -z "${snapshot_pid}" || kill -TERM "${snapshot_pid}" 2>/dev/null || true
    if test "${status}" -ne 0; then
        for log in "${TMPDIR}"/*.log; do
            test ! -f "${log}" || { echo "==> ${log}"; tail -n 40 "${log}"; }
        done
    fi
    exit "${status}"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
source_sql() { timeout 60s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "$1"; }
target_sql() { timeout 60s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "$1"; }

pretty() { printf '%X/%X' $(($1 >> 32)) $(($1 & 4294967295)); }

# runs $1 on every output.db; receive may be creating or writing the newest
spool() {
    local f
    for f in "${XDG_DATA_HOME}"/pgcopydb/*-output.db; do
        timeout 10s sqlite3 -readonly -init /dev/null -batch -noheader -list "${f}" "$1" || true
    done
}

# a KEEPALIVE spooled at or after LSN $1 (an integer)
marker_after() {
    test -n "$(spool "select 1 from output where action = 'K' and lsn >= $1 limit 1")"
}

# closed output.db files (not the last one) that open with a KEEPALIVE or
# SWITCH and hold a COMMIT after it: apply is handed only that marker on its
# first pass over the file, and must not leave the file then
closed_files_opening_with_marker() {
    local f n=0 open
    open=$(timeout 10s sqlite3 -readonly -init /dev/null -batch -noheader -list \
        "${TMPDIR}/pgcopydb/schema/source.db" \
        "select filename from cdc_files where done_time_epoch is null")
    for f in "${XDG_DATA_HOME}"/pgcopydb/*-output.db; do
        test "${f}" != "${open}" || continue
        test -n "$(timeout 10s sqlite3 -readonly -init /dev/null -batch -noheader -list "${f}" \
            "select 1 from output m
              where m.id = (select min(id) from output) and m.action in ('K', 'X')
                and exists (select 1 from output c where c.action = 'C' and c.id > m.id)")" || continue
        n=$((n + 1))
    done
    echo "${n}"
}

slot_active() {
    test "$(source_sql "select count(*) from pg_replication_slots where slot_name = 'pgcopydb' and active")" = 1
}

alive() {
    local pid
    for pid in "${prefetch_pid}" "${catchup_pid}"; do
        test -z "${pid}" || kill -0 "${pid}" 2>/dev/null || return 1
    done
}

poll() {
    local what=$1 deadline=$((SECONDS + $2))
    shift 2
    until "$@"; do
        alive || fail "pgcopydb exited while waiting for ${what}"
        test "${SECONDS}" -lt "${deadline}" || fail "timed out waiting for ${what}"
        sleep 0.5
    done
}

# wait_exit <pid> <what>: an idle source sends no keepalive past endpos, so
# emit a message that pgoutput does not publish while waiting
wait_exit() {
    local deadline=$((SECONDS + 300)) rc=0
    while kill -0 "$1" 2>/dev/null; do
        test "${SECONDS}" -lt "${deadline}" || fail "$2 did not stop at endpos ${endpos}"
        source_sql "select pg_logical_emit_message(false, 'cdc-concurrent-backlog', 'past endpos')" > /dev/null
        sleep 1
    done
    wait "$1" || rc=$?
    test "${rc}" = 0 || fail "$2 exited ${rc}"
}

# load <client> <round>: this round's overlapping multi-statement transactions
load() {
    local client=$1 round=$2 i
    for i in $(seq $(((round - 1) * txns + 1)) $((round * txns))); do
        psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" > /dev/null <<SQL
begin;
insert into burst(client, n, payload)
     select ${client}, ${i}, md5(g::text) from generate_series(1, 1 + (random() * 20)::int) g;
select pg_sleep(random() * 0.05);
insert into queue(owner, created_at)
     values (${client} * 10 + ${i} % 10, now())
     on conflict (owner) do nothing;
update burst set payload = md5(payload) where client = ${client} and n = ${i} - 1;
commit;
delete from queue where owner = ${client} * 10 + (${i} + 5) % 10;
SQL
    done
}

pgcopydb ping
source_sql '
  drop table if exists burst, queue;
  create table burst (id bigserial primary key, client int not null, n int not null, payload text not null);
  create table queue (id bigserial primary key, owner int not null unique, created_at timestamptz not null);'

pgcopydb snapshot --follow > "${TMPDIR}/snapshot.out" 2> "${TMPDIR}/snapshot.log" &
snapshot_pid=$!
timeout 60s bash -c "until test -s '${TMPDIR}/snapshot.out'; do sleep 0.2; done"
pgcopydb stream setup > "${TMPDIR}/setup.log" 2>&1
pgcopydb clone > "${TMPDIR}/clone.log" 2>&1
kill -TERM "${snapshot_pid}"
wait "${snapshot_pid}"
snapshot_pid=

# live receive, rotating after every COMMIT; apply is not running
setsid pgcopydb stream prefetch --resume --notice --max-replaydb-size 1kB > "${TMPDIR}/prefetch.log" 2>&1 &
prefetch_pid=$!
poll 'the slot to be streamed' 60 slot_active

for r in $(seq 1 "${rounds}"); do
    for c in $(seq 1 "${clients}"); do
        load "${c}" "${r}" &
        load_pids+=($!)
    done
    for pid in "${load_pids[@]}"; do wait "${pid}" || fail "a load client failed"; done
    load_pids=()

    # receive spools a KEEPALIVE on its next flush (every 10 s); the next
    # round's transactions then follow it in the spool
    flushed=$(source_sql "select pg_current_wal_flush_lsn() - '0/0'")
    poll "a KEEPALIVE after round ${r}" 60 marker_after "${flushed}"
    echo "round ${r}: KEEPALIVE spooled after $(pretty "${flushed}")"
done
endpos=$(source_sql 'select pg_current_wal_flush_lsn()')
echo "load done: $(source_sql 'select count(*) from burst') burst rows, $(source_sql 'select count(*) from queue') queue rows, endpos ${endpos}"

hits=$(closed_files_opening_with_marker)
test "${hits}" -gt 0 || fail "no closed output.db opens with a marker before a COMMIT: the test did not set up the case"
echo "ok: ${hits} closed output.db file(s) open with a marker before a COMMIT"

# apply catches up with no endpos over the closed files, receive still live
test "$(pgcopydb stream sentinel get --endpos)" = 0/0 || fail 'the sentinel has an endpos before the test set one'
pgcopydb stream sentinel set apply > "${TMPDIR}/sentinel.log" 2>&1
setsid pgcopydb stream catchup --resume --notice > "${TMPDIR}/catchup.log" 2>&1 &
catchup_pid=$!

last=$(timeout 10s sqlite3 -readonly -init /dev/null -batch -noheader -list \
    "${TMPDIR}/pgcopydb/schema/source.db" \
    "select filename from cdc_files where done_time_epoch is null")
test -n "${last}" -a "$(wc -l <<<"${last}")" = 1 || fail "expected one open output.db, got: ${last}"
reached_last() { grep -qF "Apply advanced to outputDB \"${last}\"" "${TMPDIR}/catchup.log"; }
poll 'apply to open the last output.db' 300 reached_last
echo "apply went through $(grep -c 'Apply advanced' "${TMPDIR}/catchup.log") output.db files"

pgcopydb stream sentinel set endpos "${endpos}" >> "${TMPDIR}/sentinel.log" 2>&1
wait_exit "${prefetch_pid}" prefetch
prefetch_pid=
wait_exit "${catchup_pid}" catchup
catchup_pid=

status=0
for t in burst queue; do
    q="select count(*) || ' ' || coalesce(md5(string_agg(t::text, ',' order by id)), '-') from ${t} t"
    src=$(source_sql "${q}")
    dst=$(target_sql "${q}")
    if test "${src}" = "${dst}"; then
        echo "ok: ${t} matches (${src%% *} rows)"
    else
        echo "FAIL: ${t} differs: source ${src%% *} rows, target ${dst%% *} rows"
        status=1
    fi
done
test "${status}" = 0 || fail "the target is missing source changes"

pgcopydb stream cleanup > "${TMPDIR}/cleanup.log" 2>&1
echo "PASS: live apply kept every change of ${clients} concurrent clients over a rotated backlog"
