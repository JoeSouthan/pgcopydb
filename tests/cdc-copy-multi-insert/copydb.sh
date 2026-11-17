#! /bin/bash

# COPY writes one multi-insert WAL record per heap page, and logical decoding
# gives every tuple of that record the same change lsn.  Each tuple must reach
# output.db and the target, with every output plugin, and an output.db written
# before the seq column existed must be upgraded when follow resumes on it.

set -euo pipefail

rows=${MULTI_INSERT_ROWS:-5000}
src_base=${PGCOPYDB_SOURCE_PGURI%/*}
tgt_base=${PGCOPYDB_TARGET_PGURI%/*}
snapshot_pid='' follow_pid=''

cleanup() {
    local status=$?
    trap - EXIT
    test -z "${follow_pid}" || kill -KILL -- "-${follow_pid}" 2>/dev/null || true
    test -z "${snapshot_pid}" || kill -TERM "${snapshot_pid}" 2>/dev/null || true
    if test "${status}" -ne 0; then
        tail -n 40 "${TMPDIR}/follow.log" 2>/dev/null || true
    fi
    exit "${status}"
}
trap cleanup EXIT

fail() { echo "FAIL: ${plugin}: $*" >&2; exit 1; }
source_sql() { timeout 60s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "$1"; }
target_sql() { timeout 60s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "$1"; }

# runs $1 on each output.db; a query that matches nothing prints nothing
spool() {
    local f
    for f in "${XDG_DATA_HOME}"/pgcopydb/*-output.db; do
        timeout 10s sqlite3 -readonly -init /dev/null -batch -noheader -list "${f}" "$1"
    done
}

# for xid $1: "COMMIT id|INSERT rows|lsns shared by INSERT rows"
txn() {
    spool "select coalesce(max(id) filter (where action = 'C'), '') || '|' ||
                  count(*) filter (where action = 'I') || '|' ||
                  (select count(*) from (select 1 from output
                                          where action = 'I' and xid = $1
                                          group by lsn having count(*) > 1))
             from output where xid = $1 having count(*) > 0"
}

poll() {
    local what=$1 deadline=$((SECONDS + $2))
    shift 2
    until "$@"; do
        kill -0 "${follow_pid}" 2>/dev/null || fail "follow exited while waiting for ${what}"
        test "${SECONDS}" -lt "${deadline}" || fail "timed out waiting for ${what}"
        sleep 0.2
    done
}

# prints the xid of a transaction that copies rows $2 to $3 into table $1
copy_rows() {
    {
        echo 'begin;'
        echo 'select txid_current();'
        echo "copy $1 from stdin;"
        seq "$2" "$3" | awk -v OFS='\t' '{ print $1, "copy-" $1 }'
        echo '\.'
        echo 'commit;'
    } | timeout 120s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}"
}

committed() { IFS='|' read -r commit _ <<<"$(txn "$1")" && test -n "${commit}"; }
slot_active() {
    test "$(source_sql "select count(*) from pg_replication_slots where slot_name = 'pgcopydb' and active")" = 1
}

# output.db must hold every row of xid $2 (table $1); $3 says whether the
# rows share lsns, which shows that the source wrote a multi-insert record
check_spool() {
    local commit inserted shared
    IFS='|' read -r commit inserted shared <<<"$(txn "$2")"
    echo "$1: xid $2, ${inserted} INSERT rows in output.db, ${shared} lsns shared"
    test "${inserted}" = "${rows}" || fail "$1: output.db holds ${inserted} INSERT rows of ${rows}"
    if test "$3" = shared; then
        test "${shared}" -ge 1 || fail "$1: no INSERT rows share an lsn, so COPY wrote no multi-insert"
    else
        test "${shared}" = 0 || fail "$1: INSERT rows share an lsn"
    fi
}

# compares tables $@ of the source and the target
compare() {
    local t sql
    for t in "$@"; do
        sql="copy (select * from ${t} order by id) to stdout"
        psql -X -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "${sql}" > "${TMPDIR}/src_${t}.txt"
        psql -X -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "${sql}" > "${TMPDIR}/tgt_${t}.txt"
        test -s "${TMPDIR}/src_${t}.txt"
        if ! diff -q "${TMPDIR}/src_${t}.txt" "${TMPDIR}/tgt_${t}.txt" > /dev/null; then
            echo "target ${t}: $(target_sql "select count(*) from ${t}") rows, source: $(source_sql "select count(*) from ${t}")"
            fail "table ${t} differs"
        fi
    done
}

# creates database $1 on both sides and clones it, for output plugin $2
prepare() {
    export PGCOPYDB_SOURCE_PGURI=${src_base}/$1
    export PGCOPYDB_TARGET_PGURI=${tgt_base}/$1
    export PGCOPYDB_OUTPUT_PLUGIN=$2
    export TMPDIR=/tmp/$1
    export XDG_DATA_HOME=${TMPDIR}/cdc
    mkdir -p "${TMPDIR}"

    psql -X -v ON_ERROR_STOP=1 -d "${src_base}/postgres" -c "create database $1"
    psql -X -v ON_ERROR_STOP=1 -d "${tgt_base}/postgres" -c "create database $1"
    psql -X -q -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -f /usr/src/pgcopydb/ddl.sql

    pgcopydb snapshot --follow > "${TMPDIR}/snapshot.out" 2> "${TMPDIR}/snapshot.log" &
    snapshot_pid=$!
    timeout 60s bash -c "until test -s '${TMPDIR}/snapshot.out'; do sleep 0.2; done"
    pgcopydb stream setup
    pgcopydb clone
    kill -TERM "${snapshot_pid}"
    wait "${snapshot_pid}"
    snapshot_pid=
    pgcopydb stream sentinel set apply
}

start_follow() {
    setsid pgcopydb follow --resume --not-consistent --notice >> "${TMPDIR}/follow.log" 2>&1 &
    follow_pid=$!
    poll 'the slot to be streamed' 60 slot_active
}

stop_follow() {
    local deadline=$((SECONDS + 300))
    pgcopydb stream sentinel set endpos --current
    while kill -0 "${follow_pid}" 2>/dev/null; do
        test "${SECONDS}" -lt "${deadline}" || fail 'follow did not reach endpos'
        sleep 1
    done
    wait "${follow_pid}" || fail "follow exited with $?"
    follow_pid=
}

pgcopydb ping

for plugin in pgoutput test_decoding wal2json; do
    prepare "multi_insert_${plugin}" "${plugin}"
    start_follow

    # COPY into a table and into a partitioned table; INSERT ... SELECT
    # writes one WAL record per row and is the control
    xid_copy=$(copy_rows t_copy 1 "${rows}")
    xid_part=$(copy_rows p_copy 1 "${rows}")
    xid_ins=$(source_sql "begin; select txid_current(); insert into t_ins select g, 'ins-' || g from generate_series(1, ${rows}) g; commit")
    for x in "${xid_copy}" "${xid_part}" "${xid_ins}"; do
        poll "xid ${x} in output.db" 120 committed "${x}"
    done
    check_spool t_copy "${xid_copy}" shared
    check_spool p_copy "${xid_part}" shared
    check_spool t_ins "${xid_ins}" distinct

    source_sql 'insert into tx values (1)'
    stop_follow
    compare tx t_copy t_ins p_copy
    pgcopydb stream cleanup
    echo "PASS: ${plugin}"
done

# An output.db written before seq existed keys its rows on (action, lsn).
# Follow resumes on it and upgrades it before replication starts.
plugin=upgrade
prepare multi_insert_upgrade pgoutput
start_follow
source_sql "insert into t_ins select g, 'old-' || g from generate_series(1, ${UPGRADE_ROWS:-300000}) g"
source_sql 'insert into tx values (1)'
stop_follow

for f in "${XDG_DATA_HOME}"/pgcopydb/*-output.db; do
    sqlite3 -init /dev/null -batch "${f}" \
        "drop index o_a_lsn_seq;
         alter table output drop column seq;
         create unique index o_a_lsn on output(action, lsn)"
done
schema() {
    spool "select group_concat(name, ',') from (select name from pragma_table_info('output')
                                                where name = 'seq'
                                               union all
                                               select name from pragma_index_list('output')
                                               order by name)"
}
echo "old output.db: $(spool 'select count(*) from output') rows, seq and indexes: $(schema)"
test "$(schema)" = o_a_id,o_a_lsn,o_a_xid || fail "output.db does not have the old schema: $(schema)"

pgcopydb stream sentinel set endpos 0/0
start_follow
xid_copy=$(copy_rows t_copy 1 "${rows}")
poll "xid ${xid_copy} in output.db" 120 committed "${xid_copy}"
check_spool t_copy "${xid_copy}" shared
echo "upgraded output.db: seq and indexes: $(schema)"
test "$(schema)" = o_a_id,o_a_lsn_seq,o_a_xid,seq || fail "output.db was not upgraded: $(schema)"
source_sql 'insert into tx values (2)'
stop_follow
compare tx t_copy t_ins
test "$(grep -c ' ERROR ' "${TMPDIR}/follow.log")" = 0 || fail 'the resume logged errors'
test "$(grep -c 'Adding column output.seq' "${TMPDIR}/follow.log")" = 1 || fail 'the upgrade did not run once'
pgcopydb stream cleanup
echo "PASS: ${plugin}"
