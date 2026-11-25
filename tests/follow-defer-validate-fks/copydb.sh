#! /bin/bash

# With clone --follow --defer-validate-fks, the foreign keys are validated
# after the source snapshot is released, while the changes are applied. A
# failed validation is recorded and does not stop the follow process, and a
# resumed run validates what is left. A stop, or a failure of the follow
# process, cancels the running validation. At endpos, pgcopydb exits with an
# error while foreign keys are left to validate.

set -x -e -o pipefail

# give each background pgcopydb its own process group, to signal all of it
set -m

clone_pid=

cleanup() {
    local status=$?
    trap - EXIT
    test -z "${clone_pid}" || kill -KILL -- "-${clone_pid}" 2>/dev/null || true
    if test "${status}" -ne 0; then
        for log in /tmp/clone*.log; do
            test ! -f "${log}" || { echo "==> ${log}"; tail -n 60 "${log}"; }
        done
    fi
    exit "${status}"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# kill -0 succeeds on a zombie, which a background job is until waited for
alive() {
    local state
    state=$(cut -d' ' -f3 "/proc/$1/stat" 2>/dev/null) || return 1
    test "${state}" != Z
}

# wait for the background pgcopydb, for at most $1 seconds
wait_clone() {
    local deadline=$((SECONDS + $1))
    while alive "${clone_pid}"; do
        test "${SECONDS}" -lt "${deadline}" || fail "pgcopydb is still running"
        sleep 0.5
    done
    local pid=${clone_pid}
    clone_pid=
    wait "${pid}"
}

for i in $(seq 1 30); do
    pgcopydb ping && break
    sleep 1
done

psql -d "${PGCOPYDB_SOURCE_PGURI}" -v ON_ERROR_STOP=1 -f fixture.sql

dbfile=/tmp/pgcopydb/schema/source.db

catalog_sql() {
    sqlite3 -readonly -init /dev/null -batch -noheader -list "${dbfile}" "$1" \
        2>/dev/null || true
}

src() { psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "$1"; }
tgt() { psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "$1"; }

validation_status() {
    catalog_sql "select v.status
                   from fk_validation_summary v
                   join s_fk_constraint f on f.oid = v.conoid
                  where f.conname = '$1'"
}

# pending: created and not validated yet; failed: the last attempt failed
validation_counts() {
    catalog_sql "select
        (select count(*)
           from fk_constraint_summary s
                left join fk_validation_summary v on v.conoid = s.conoid
          where s.status = 'created'
            and (v.status is null or v.status <> 'validated'))
        || ' ' ||
        (select count(*) from fk_validation_summary where status = 'failed')"
}

wait_for_counts() {
    local deadline=$((SECONDS + $2))
    while test "$(validation_counts)" != "$1"; do
        alive "${clone_pid}" || fail "pgcopydb exited waiting for counts $1"
        test "${SECONDS}" -lt "${deadline}" || fail "counts are not $1: $(validation_counts)"
        sleep 0.5
    done
}

# a row inserted into legacy on the source is applied on the target
check_apply() {
    src "insert into legacy values ($1, 1)"

    local deadline=$((SECONDS + 30))
    while test "$(tgt "select count(*) from legacy where id = $1")" != 1; do
        test "${SECONDS}" -lt "${deadline}" || fail "row $1 was not applied"
        sleep 0.5
    done
}

# pids of the processes that run the given ps title, see set_ps_title
pids_of() {
    local f
    { set +x; } 2>/dev/null
    for f in /proc/[0-9]*/cmdline; do
        if test "$(tr -d '\0' < "${f}" 2>/dev/null)" = "$1"; then
            f=${f#/proc/}
            echo "${f%/cmdline}"
        fi
    done
    set -x
}

# pgcopydb VALIDATE CONSTRAINT queries running on the target
validate_backends() {
    tgt "select count(*) from pg_stat_activity
          where query ilike 'ALTER TABLE ONLY % VALIDATE CONSTRAINT %'
            and pid <> pg_backend_pid()"
}

# no VALIDATE CONSTRAINT is left running on the target, shortly after
check_no_validate_backend() {
    local deadline=$((SECONDS + 5))
    while test "$(validate_backends)" != 0; do
        test "${SECONDS}" -lt "${deadline}" || fail "a validation is left running on the target"
        sleep 0.5
    done
}

wait_for_validate_backend() {
    local deadline=$((SECONDS + 30))
    while test "$(validate_backends)" != 1; do
        test "${SECONDS}" -lt "${deadline}" || fail "the validation is not running on the target"
        sleep 0.1
    done
}

# the sessions of a killed pgcopydb are gone from the source and the target
wait_for_no_sessions() {
    local deadline=$((SECONDS + 60))
    until test "$(src "select count(*) from pg_replication_slots where active")" = 0 &&
          test "$(tgt "select count(*) from pg_stat_activity
                        where application_name like 'pgcopydb%'")" = 0; do
        test "${SECONDS}" -lt "${deadline}" || fail "pgcopydb sessions are left"
        sleep 0.5
    done
}

wait_for_big_child_running() {
    local deadline=$((SECONDS + 300))
    until test "$(validation_status big_child_parent_k_fkey)" = running; do
        alive "${clone_pid}" || fail "pgcopydb exited before validating big_child"
        test "${SECONDS}" -lt "${deadline}" || fail "big_child is never validated"
        sleep 0.1
    done
}

start_resume() {
    pgcopydb clone --follow --defer-validate-fks --plugin pgoutput \
        --index-jobs 1 --resume --not-consistent --notice \
        > "/tmp/clone-$1.log" 2>&1 &
    clone_pid=$!
}

#
# 1. clone --follow with --defer-validate-fks
#
pgcopydb clone --follow --defer-validate-fks --plugin pgoutput \
    --index-jobs 1 --notice > /tmp/clone.log 2>&1 &
clone_pid=$!

#
# 2. while big_child's foreign key is being validated
#
wait_for_big_child_running

# no pgcopydb session on the source holds a snapshot
src "select pid, application_name, backend_type, backend_xmin
       from pg_stat_activity
      where application_name like 'pgcopydb%'"

test "$(src "select count(*) from pg_stat_activity
              where application_name like 'pgcopydb%'
                and backend_xmin is not null")" = 0

test "$(pgcopydb stream sentinel get --apply)" = enabled

check_apply 1001

# the change was applied while the validation was still running
test "$(validation_status big_child_parent_k_fkey)" = running

#
# 3. stop pgcopydb during the validation: the query is cancelled on the
#    target, and the foreign key is left to validate
#
wait_for_validate_backend

kill -TERM -- "-${clone_pid}"
wait_clone 60 || true

check_no_validate_backend
test "$(validation_status big_child_parent_k_fkey)" = running

#
# 4. when the follow process fails during the validation, pgcopydb stops the
#    validation and exits, rather than wait for it
#
start_resume follow-fails
wait_for_big_child_running
wait_for_validate_backend

follow_pid=$(pids_of "pgcopydb: follow")
test -n "${follow_pid}" || fail "the follow process is not found"
kill -KILL "${follow_pid}"

pgid=${clone_pid}

if wait_clone 60; then
    fail "pgcopydb must fail when the follow process fails"
fi

# the follow sub-processes are left without their parent
kill -KILL -- "-${pgid}" 2>/dev/null || true
wait_for_no_sessions

grep "Stopping the foreign key validations" /tmp/clone-follow-fails.log
check_no_validate_backend
test "$(validation_status big_child_parent_k_fkey)" = running

#
# 5. resume: all the validations are done, "Mixed Case FK" has failed
#
start_resume failed

wait_for_counts "1 1" 600

test "$(validation_status '"Mixed Case FK"')" = failed

catalog_sql "select v.error
               from fk_validation_summary v
               join s_fk_constraint f on f.oid = v.conoid
              where f.conname = '\"Mixed Case FK\"'" | grep 23503

test "$(catalog_sql "select count(*)
                       from fk_validation_summary v
                       join s_fk_constraint f on f.oid = v.conoid
                      where f.conname = 'legacy_parent_fk'")" = 0

test "$(validation_status child_parent_id_fkey)" = validated
test "$(validation_status big_child_parent_k_fkey)" = validated

# the follow process carries on
alive "${clone_pid}"
test "$(pgcopydb stream sentinel get --apply)" = enabled
check_apply 1002

#
# 6. fix the orphan on the source and wait for the delete, then reach endpos:
#    pgcopydb exits with an error, a foreign key failed to validate
#
src "delete from \"Order Items\" where id = 100001"

deadline=$((SECONDS + 30))
while test "$(tgt "select count(*) from \"Order Items\" where id = 100001")" != 0; do
    test "${SECONDS}" -lt "${deadline}" || fail "the orphan delete was not applied"
    sleep 0.5
done

src "select pg_switch_wal()"
pgcopydb stream sentinel set endpos --current

status=0
wait_clone 300 || status=$?
test "${status}" = 7 || fail "pgcopydb must exit 7 at endpos, not ${status}"

grep "1 deferred foreign key(s) are left NOT VALID on the target, of which 1 failed to validate" \
    /tmp/clone-failed.log

#
# 7. resume, the endpos is reached already: the failed validation is retried
#    and pgcopydb exits with success
#
start_resume validated
wait_clone 300

test "$(validation_counts)" = "0 0"
test "$(validation_status '"Mixed Case FK"')" = validated

#
# 8. every foreign key on the target is validated, but the one that is not
#    valid on the source
#
tgt "select conname, convalidated from pg_constraint where contype = 'f'
      order by conname"

test "$(tgt "select count(*) from pg_constraint where contype = 'f'")" = 4

test "$(tgt "select string_agg(conname, ',' order by conname)
               from pg_constraint
              where contype = 'f' and not convalidated")" = legacy_parent_fk

grep -h "VALIDATE CONSTRAINT\|alidat" /tmp/clone*.log
