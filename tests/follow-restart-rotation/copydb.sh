#! /bin/bash

set -x
set -e

# This script expects the following environment variables to be set:
#
#  - PGCOPYDB_SOURCE_PGURI
#  - PGCOPYDB_TARGET_PGURI
#  - PGCOPYDB_TABLE_JOBS
#
# What this test covers
# =====================
#
# pgcopydb clone --follow restarts its sub-processes in place when apply
# fails.  The receive process that is started again must spool into the
# output.db file that is open in cdc_files.  The process that created the
# replication slot also created the first output.db, named after the slot
# LSN, and every sub-process inherits that name across fork().  Once receive
# has rotated to another file, a restarted receive that trusted the inherited
# name wrote into the first file, which apply had already left, and reported
# those transactions as flushed: the source never sent them again and they
# never reached the target.
#
# The test rotates after every COMMIT, makes apply fail on a table that is
# missing on the target (as a partition created on the source only does),
# inserts rows while the sub-processes restart, then creates the table on
# the target so that apply can carry on.  Every row must reach the target.
#
# Then pruning the applied CDC files must remove each of them with its -wal
# and -shm files, never leave those behind on their own.

ROWS=50

# show what pgcopydb did when a step fails
trap 'test $? -eq 0 || tail -n 200 /tmp/clone.log' EXIT

# make sure source and target databases are ready
pgcopydb ping

psql -d ${PGCOPYDB_SOURCE_PGURI} -c "
  create table t(id bigint generated always as identity primary key, note text)"

psql -d ${PGCOPYDB_SOURCE_PGURI} -c "
  create table victim(id bigint primary key)"

psql -d ${PGCOPYDB_SOURCE_PGURI} -c "
  insert into t(note) select 'seed-'||g from generate_series(1,${ROWS}) g"

pgcopydb clone --follow --notice --max-replaydb-size 1kB \
    --max-restarts 100 --restart-window 600 \
    > /tmp/clone.log 2>&1 &
clone_pid=$!

# wait for the slot to be streaming
slot_active=0

for i in $(seq 1 120)
do
    slot_active=$(psql -AtqX -d ${PGCOPYDB_SOURCE_PGURI} -c "
      select count(*) from pg_replication_slots
       where slot_name = 'pgcopydb' and active")

    test "${slot_active}" = "1" && break
    sleep 1
done

test "${slot_active}" = "1"

# one transaction per row, so that receive rotates after each of them
insert_rows() {
    seq 1 $2 \
        | sed "s/.*/insert into t(note) values ('$1-&');/" \
        | psql -q -d ${PGCOPYDB_SOURCE_PGURI}
}

count_rows() {
    psql -AtqX -d "$1" -c "select count(*) from $2"
}

# wait until the target has all the rows of the source
wait_for_rows() {
    for i in $(seq 1 180)
    do
        src=$(count_rows ${PGCOPYDB_SOURCE_PGURI} t)
        tgt=$(count_rows ${PGCOPYDB_TARGET_PGURI} t)
        echo "rows: source ${src}, target ${tgt}"
        test "${src}" = "${tgt}" && return 0
        sleep 1
    done

    return 1
}

restarts() {
    grep -c "Restarting follow sub-processes" /tmp/clone.log || true
}

# wait until the follow sub-processes have been restarted $1 times
wait_for_restarts() {
    for i in $(seq 1 120)
    do
        test "$(restarts)" -ge "$1" && return 0
        sleep 1
    done

    return 1
}

insert_rows before 10
wait_for_rows

# receive has left the output.db that was created with the replication slot
test "$(grep -c 'Rotated to new outputDB' /tmp/clone.log)" -ge 2

#
# apply fails on a table that the target does not have
#
psql -d ${PGCOPYDB_TARGET_PGURI} -c "drop table victim"
psql -d ${PGCOPYDB_SOURCE_PGURI} -c "insert into victim values (1)"

wait_for_restarts 1

# rows committed while the sub-processes keep failing and restarting: each
# restarted receive streams them
for round in 1 2 3
do
    insert_rows "restart-${round}" 5
    wait_for_restarts $(( $(restarts) + 1 ))
done

#
# the table now exists on the target, apply carries on
#
psql -d ${PGCOPYDB_TARGET_PGURI} -c "create table victim(id bigint primary key)"

insert_rows after 10
wait_for_rows

pgcopydb stream sentinel set endpos --current

wait ${clone_pid}

src=$(count_rows ${PGCOPYDB_SOURCE_PGURI} t)
tgt=$(count_rows ${PGCOPYDB_TARGET_PGURI} t)

echo "rows: source ${src}, target ${tgt}"

test $((ROWS + 10 + 15 + 10)) -eq "${src}"
test "${src}" -eq "${tgt}"
test "$(count_rows ${PGCOPYDB_TARGET_PGURI} victim)" -eq 1

#
# pruning the applied CDC files removes their -wal and -shm files too.  The
# sub-processes that were killed in the restarts may or may not have left
# some behind, so make sure that every CDC file has them.
#
cdc=${XDG_DATA_HOME:-${HOME}/.local/share}/pgcopydb

for f in ${cdc}/*-output.db ${cdc}/*-replay.db
do
    test -e "${f}-wal" || touch "${f}-wal"
    test -e "${f}-shm" || touch "${f}-shm"
done

pgcopydb stream prune > /tmp/prune.log 2>&1
cat /tmp/prune.log
grep "Removed CDC output file" /tmp/prune.log

for f in ${cdc}/*-wal ${cdc}/*-shm
do
    test -e "${f}" || continue
    test -e "${f%-???}" || { echo "left behind: ${f}"; exit 1; }
done

pgcopydb stream cleanup
