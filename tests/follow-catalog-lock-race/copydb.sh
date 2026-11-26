#! /bin/bash

# During clone --follow, the follow process writes to the source catalog
# (cdc_files on every CDC file rotation) while the CREATE INDEX workers build
# constraints. Each worker iterates over a table's indexes in the catalog and
# records every constraint in the summary table from the iteration callback.
# A write committed by another process during that iteration made the
# worker's next write fail with SQLITE_BUSY_SNAPSHOT ("database is locked"),
# which no retry recovers from, and --fail-fast stopped the whole clone.
#
# Here a tiny --max-replaydb-size rotates the CDC file at nearly every source
# transaction, while the clone builds 192 unique constraints, and an exclusion
# constraint whose ALTER TABLE builds an index over 3 million rows: the follow
# process commits to the catalog while that command runs.

set -x -e -o pipefail

set -m

clone_pid=
writer_pid=

cleanup() {
    local status=$?
    trap - EXIT
    test -z "${writer_pid}" || kill -KILL "${writer_pid}" 2>/dev/null || true
    test -z "${clone_pid}" || kill -KILL -- "-${clone_pid}" 2>/dev/null || true
    if test "${status}" -ne 0 && test -f /tmp/clone.log; then
        grep -E 'ERROR|FATAL' /tmp/clone.log | head -n 40 || true
        tail -n 40 /tmp/clone.log
    fi
    exit "${status}"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

alive() {
    local state
    state=$(cut -d' ' -f3 "/proc/$1/stat" 2>/dev/null) || return 1
    test "${state}" != Z
}

for i in $(seq 1 30); do
    pgcopydb ping && break
    sleep 1
done

psql -d "${PGCOPYDB_SOURCE_PGURI}" -v ON_ERROR_STOP=1 -q -f fixture.sql

# one transaction per insert, for as long as the test runs
yes 'insert into ticks default values;' |
    psql -d "${PGCOPYDB_SOURCE_PGURI}" -q -o /dev/null > /dev/null 2>&1 &
writer_pid=$!

pgcopydb clone --follow --plugin pgoutput \
    --table-jobs 2 --index-jobs 4 \
    --max-replaydb-size 1kB --notice > /tmp/clone.log 2>&1 &
clone_pid=$!

# the clone is done once apply is enabled
deadline=$((SECONDS + 600))
until test "$(pgcopydb stream sentinel get --apply 2>/dev/null)" = enabled; do
    alive "${clone_pid}" || fail "pgcopydb exited before the clone was done"
    test "${SECONDS}" -lt "${deadline}" || fail "the clone is not done"
    sleep 0.5
done

kill -KILL "${writer_pid}"
wait "${writer_pid}" 2>/dev/null || true
writer_pid=

# the follow process rotated its CDC file while the constraints were built
rotations=$(grep -c 'rotating' /tmp/clone.log || true)
echo "CDC file rotations: ${rotations}"
test "${rotations}" -gt 20 || fail "too few CDC file rotations: ${rotations}"

# every constraint is on the target
test "$(psql -AtqX -d "${PGCOPYDB_TARGET_PGURI}" \
        -c "select count(*) from pg_constraint
             where contype = 'u' and conrelid::regclass::text like 'items_%'")" = 192

test "$(psql -AtqX -d "${PGCOPYDB_TARGET_PGURI}" \
        -c "select count(*) from pg_constraint
             where contype = 'x' and conrelid = 'public.slots'::regclass")" = 1

# --notice logs the retries of a busy catalog write; none of them may fail
grep 'database is locked' /tmp/clone.log | sort -k4 | uniq -c -f3 | head -n 20 || true
! grep -E ' ERROR .*(database is locked|Failed to execute statement)' /tmp/clone.log ||
    fail "a catalog write failed"

psql -d "${PGCOPYDB_SOURCE_PGURI}" -c "select pg_switch_wal()" > /dev/null
pgcopydb stream sentinel set endpos --current

deadline=$((SECONDS + 300))
while alive "${clone_pid}"; do
    test "${SECONDS}" -lt "${deadline}" || fail "pgcopydb did not reach endpos"
    sleep 0.5
done

pid=${clone_pid}
clone_pid=
wait "${pid}"
