#! /bin/bash

# A KEEPALIVE handed to the transform while it holds an open transaction.
#
# The transform keeps a transaction whose COMMIT receive has not written yet
# in memory from one pass to the next, and it reads KEEPALIVE markers with a
# cursor of its own. After receive goes back to the server and sends the
# transaction again, its rows get new ids, and a KEEPALIVE written before them
# comes first. The transform must write that KEEPALIVE on its own, and keep
# the transaction it holds.
#
# The suite spools one transaction, takes its COMMIT away as if receive were
# still sending it, and starts the catchup. Once the catchup has written the
# open transaction to replayDB, it adds a KEEPALIVE and sends the transaction
# again, then gives it back its COMMIT. The catchup must apply the
# transaction and reach the end position.

set -x
set -e
set -o pipefail

pgcopydb ping

psql -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" \
     -c "create table t(id integer primary key, v text)"

coproc ( pgcopydb snapshot --follow )

sleep 1

pgcopydb stream setup
pgcopydb clone

kill -TERM ${COPROC_PID}
wait ${COPROC_PID}

psql -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" \
     -c "insert into t select g, 'v' || g from generate_series(1, 100) g"

lsn=$(psql -At -d "${PGCOPYDB_SOURCE_PGURI}" -c 'select pg_current_wal_flush_lsn()')

pgcopydb stream prefetch --resume --endpos "${lsn}"

SHAREDIR=/var/lib/postgres/.local/share/pgcopydb
SOURCEDB=$( (find "${TMPDIR:-/tmp}" /var/lib/postgres -path "*/schema/source.db" -type f 2>/dev/null || true) | head -1)
test -n "${SOURCEDB}"
OUTPUTDB=$(find ${SHAREDIR} -maxdepth 1 -name '*-output.db' -type f | head -1)

out() {
    sqlite3 -bail -init /dev/null -batch -noheader -list "${OUTPUTDB}" "$1"
}

xid=$(out "select xid from output where action = 'B' order by id limit 1")
begin_lsn=$(out "select lsn from output where action = 'B' and xid = ${xid}")
test "$(out "select count(*) from output where action = 'I' and xid = ${xid}")" = 100

# receive is still sending the transaction: no COMMIT yet
out "create table saved_commit as
       select action, xid, lsn, timestamp, message, nspname, relname, old_type, seq
         from output where action = 'C' and xid = ${xid};
     delete from output where action = 'C' and xid = ${xid}"

sqlite3 -bail -init /dev/null "${SOURCEDB}" \
    "update pipeline_state set run_state = 'running', run_end_lsn = null
      where process_name = 'receive'"

pgcopydb stream sentinel set apply

pgcopydb stream catchup --resume --endpos "${lsn}" -v > /tmp/catchup.log 2>&1 &
catchup_pid=$!

# wait until the catchup has written the open transaction to replayDB
for i in $(seq 1 120); do
    REPLAYDB=$(find ${SHAREDIR} -maxdepth 1 -name '*-replay.db' -type f | head -1)
    if [ -n "${REPLAYDB}" ] &&
       [ "$(sqlite3 -init /dev/null -batch -noheader "${REPLAYDB}" \
             "select count(*) from replay where action = 'B' and endlsn is null" \
             2>/dev/null || echo 0)" = 1 ]
    then
        break
    fi
    kill -0 ${catchup_pid}
    sleep 0.5
done
test "$(sqlite3 -init /dev/null -batch -noheader "${REPLAYDB}" \
         "select count(*) from replay where action = 'B' and endlsn is null")" = 1

# receive went back to the server: a KEEPALIVE, then the transaction again,
# whose rows take new ids
out "begin;
     create temp table resend as
       select action, xid, lsn, timestamp, message, nspname, relname, old_type, seq
         from output where xid = ${xid} order by id;
     insert into output(action, xid, lsn, timestamp)
          values ('K', null, ${begin_lsn}, strftime('%Y-%m-%d %H:%M:%f+00', 'now'));
     insert or replace into output(action, xid, lsn, timestamp, message,
                                   nspname, relname, old_type, seq)
          select * from resend;
     commit"

# give the catchup a few passes over that
sleep 3
kill -0 ${catchup_pid} || { cat /tmp/catchup.log; exit 1; }

# and the COMMIT
out "insert into output(action, xid, lsn, timestamp, message, nspname,
                        relname, old_type, seq)
          select * from saved_commit"

rc=0
wait ${catchup_pid} || rc=$?

grep -E 'ERROR|FATAL|BUG' /tmp/catchup.log || true
test ${rc} -eq 0

test "$(psql -At -d "${PGCOPYDB_TARGET_PGURI}" -c 'select count(*) from t')" = 100

pgcopydb stream cleanup
