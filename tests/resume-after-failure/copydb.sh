#! /bin/bash

# A clone that was interrupted, or that failed, resumes to completion.
#
# The scenario runs a complete clone, then puts the catalog and the target
# back into the state that an interrupted run leaves behind, and checks that
# --resume finishes the job:
#
#  - split: tables copied in several parts, all done, and no foreign key on
#    the target yet to prevent a TRUNCATE.

set -x -e -o pipefail

for i in $(seq 1 30); do
    pgcopydb ping && break
    sleep 1
done

psql -d "${PGCOPYDB_SOURCE_PGURI}" -v ON_ERROR_STOP=1 -f fixture.sql

admin_uri="${PGCOPYDB_TARGET_PGURI}"

opts="--table-jobs 2 --index-jobs 2 --split-tables-larger-than 64kB"
opts="${opts} --defer-validate-fks --notice"

src() {
    psql -AtqX -d "${PGCOPYDB_SOURCE_PGURI}" -c "$1"
}

tgt() {
    psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "$1"
}

catalog_sql() {
    sqlite3 -readonly -init /dev/null -batch -noheader -list \
            "${dir}/schema/source.db" "$1"
}

catalog_edit() {
    sqlite3 -bail -init /dev/null -batch "${dir}/schema/source.db" "$1"
}

setup() {
    name=$1
    dir=/tmp/${name}

    psql -d "${admin_uri}" -c "drop database if exists ${name}" \
         -c "create database ${name}"
    export PGCOPYDB_TARGET_PGURI="${admin_uri%/*}/${name}"

    pgcopydb clone --dir "${dir}" ${opts} > "/tmp/${name}-first.log" 2>&1
}

# the tables copied in several parts keep their rows when the clone resumes
# after its COPY was done: the workers skip the parts that are done, so a
# TRUNCATE of the table would lose them. With --defer-validate-fks the target
# has no foreign key yet before the post-data restore, nothing that would
# make the TRUNCATE fail. This scenario is about the rows: no VACUUM.
scenario_split() {
    setup split

    catalog_edit "update timings set done_time_epoch = null, duration = null
                   where id in (4, 6, 12)"
    tgt "alter table child drop constraint child_parent_id_fkey"

    test "$(catalog_sql "select count(*)
                           from s_table t
                          where t.relname in ('parent', 'split_t')
                            and (select count(*) from s_table_part p
                                  where p.oid = t.oid) > 1")" = 2

    local rc=0 t q

    pgcopydb clone --dir "${dir}" ${opts} --resume --not-consistent \
             --skip-vacuum > "/tmp/${name}-resume.log" 2>&1 || rc=$?

    grep -E 'TRUNCATE|ERROR|FATAL' "/tmp/${name}-resume.log" || true

    for t in parent child split_t con_a con_b plain_t pt; do
        q="select count(*) from ${t}"
        test "$(tgt "$q")" = "$(src "$q")"
    done

    test ${rc} -eq 0
}

failed=""

for s in ${SCENARIOS:-split}; do
    set +e
    (set -e; scenario_${s})
    rc=$?
    set -e

    if [ ${rc} -ne 0 ]; then
        failed="${failed} ${s}"
    fi
done

if [ -n "${failed}" ]; then
    echo "FAILED scenarios:${failed}"
    exit 1
fi
