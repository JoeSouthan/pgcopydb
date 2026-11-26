#! /bin/bash

# A clone that was interrupted, or that failed, resumes to completion.
#
# Each scenario runs a complete clone, then puts the catalog and the target
# back into the state that an interrupted or failed run leaves behind, and
# checks that --resume finishes the job:
#
#  - split: tables copied in several parts, all done, and no foreign key on
#    the target yet to prevent a TRUNCATE;
#  - postdata: a post-data restore that went through but was not recorded as
#    done, with the foreign keys that --defer-validate-fks creates after it
#    never reached.

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

# timings ids: 11 finalize schema (post-data), 12 total
interrupt_post_data() {
    catalog_edit "update timings set done_time_epoch = null, duration = null
                   where id in (11, 12)"
}

setup() {
    name=$1
    dir=/tmp/${name}

    psql -d "${admin_uri}" -c "drop database if exists ${name}" \
         -c "create database ${name}"
    export PGCOPYDB_TARGET_PGURI="${admin_uri%/*}/${name}"

    pgcopydb clone --dir "${dir}" ${opts} > "/tmp/${name}-first.log" 2>&1
}

resume() {
    if ! pgcopydb clone --dir "${dir}" ${opts} --resume --not-consistent \
         > "/tmp/${name}-resume.log" 2>&1
    then
        grep -E 'ERROR|FATAL|line ignored|indexes .supporting|Found [0-9]+ indexes on target' "/tmp/${name}-resume.log" | head -40
        return 1
    fi
}

# the target has the same indexes, constraints, triggers and statistics as
# the source, each once, the foreign keys validated, and our catalogs have
# all the work done
check_complete() {
    local q t

    for t in parent child split_t con_a con_b plain_t pt; do
        q="select count(*) from ${t}"
        test "$(tgt "$q")" = "$(src "$q")"
    done

    q="select string_agg(indexname, ',' order by indexname)
         from pg_indexes where schemaname = 'public'"
    test "$(tgt "$q")" = "$(src "$q")"

    q="select string_agg(conname || ':' || contype::text || ':' || convalidated::text,
                         ',' order by conname)
         from pg_constraint where connamespace = 'public'::regnamespace"
    test "$(tgt "$q")" = "$(src "$q")"

    q="select string_agg(tgname, ',' order by tgname)
         from pg_trigger where not tgisinternal"
    test "$(tgt "$q")" = "$(src "$q")"

    q="select string_agg(stxname, ',' order by stxname) from pg_statistic_ext"
    test "$(tgt "$q")" = "$(src "$q")"

    test "$(catalog_sql "select count(*) from s_index i
                          where not exists
                                (select 1 from summary s
                                  where s.indexoid = i.oid
                                    and s.done_time_epoch is not null)")" = 0

    test "$(catalog_sql "select count(*) from s_constraint c
                          where not exists
                                (select 1 from summary s
                                  where s.conoid = c.oid
                                    and s.done_time_epoch is not null)")" = 0

    test "$(catalog_sql "select count(*) from vacuum_summary
                          where done_time_epoch is not null")" = \
         "$(catalog_sql "select count(*) from s_table")"

    # each entry of the post-data restore list appears once
    test "$(grep -E '^;?[0-9]+;' "${dir}/schema/post-filtered.list" \
              | sed -E 's/^;?([0-9]+);.*/\1/' | sort | uniq -d | wc -l)" = 0

    if grep -q 'line ignored' "/tmp/${name}-resume.log"; then
        return 1
    fi
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

# the post-data restore went through, but the run failed before it was
# recorded as done, and before the foreign keys were created
scenario_postdata() {
    setup postdata
    interrupt_post_data

    tgt "alter table child drop constraint child_parent_id_fkey"
    catalog_edit "delete from fk_validation_summary;
                  delete from fk_constraint_summary"

    # the post-data restore list of the failed attempt is still there
    test -s "${dir}/schema/post-filtered.list"

    resume
    check_complete
}

failed=""

for s in ${SCENARIOS:-split postdata}; do
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
