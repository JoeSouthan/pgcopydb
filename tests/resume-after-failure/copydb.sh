#! /bin/bash

# A clone that was interrupted, or that failed, resumes to completion.
#
# Each scenario runs a complete clone, then puts the catalog and the target
# back into the state that an interrupted or failed run leaves behind, and
# checks that --resume finishes the job:
#
#  - split: tables copied in several parts, all done, and no foreign key on
#    the target yet to prevent a TRUNCATE;
#  - vacuum: tables vacuumed by the previous run, and one VACUUM in flight;
#  - constraints: a worker killed while it held a table's "parts done" or
#    "indexes done" claim, a CREATE INDEX and an ALTER TABLE ADD CONSTRAINT
#    that the server finished after pgcopydb had gone, and a constraint whose
#    index was built but not the constraint itself, with a catalog written by
#    an older pgcopydb;
#  - postdata: a post-data restore that went through but was not recorded as
#    done, with the foreign keys that --defer-validate-fks creates after it
#    never reached;
#  - dump: a pg_dump killed while it wrote the schema dump, which leaves a
#    truncated archive behind.

set -x -e -o pipefail

for i in $(seq 1 30); do
    pgcopydb ping && break
    sleep 1
done

psql -d "${PGCOPYDB_SOURCE_PGURI}" -v ON_ERROR_STOP=1 -f fixture.sql

admin_uri="${PGCOPYDB_TARGET_PGURI}"

opts="--table-jobs 2 --index-jobs 2 --split-tables-larger-than 64kB"
opts="${opts} --defer-validate-fks --notice"

# a pid that no process has
stale_pid=4194000

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

# index_oid <index name>, constraint_oid <constraint name>, table_oid <name>
index_oid() {
    catalog_sql "select oid from s_index where relname = '$1'"
}

constraint_oid() {
    catalog_sql "select oid from s_constraint where conname = '$1'"
}

table_oid() {
    catalog_sql "select oid from s_table where relname = '$1'"
}

# timings ids: 4 total data, 6 create index, 7 alter table, 8 vacuum,
# 11 finalize schema (post-data), 12 total
interrupt_index_phase() {
    catalog_edit "update timings set done_time_epoch = null, duration = null
                   where id in (4, 6, 7, 8, 11, 12)"
}

interrupt_post_data() {
    catalog_edit "update timings set done_time_epoch = null, duration = null
                   where id in (11, 12)"
}

# the state of a run killed before any of its work after the catalogs was
# recorded as done: timings from the given id on are not done, and the
# summaries of the COPY, CREATE INDEX, constraints and VACUUM are empty
reset_after() {
    catalog_edit "update timings set done_time_epoch = null, duration = null
                   where id >= $1;
                  delete from summary;
                  delete from s_table_parts_done;
                  delete from s_table_indexes_done;
                  delete from vacuum_summary;
                  delete from fk_validation_summary;
                  delete from fk_constraint_summary"
}

# an empty target database, named after the scenario
empty_target() {
    psql -d "${admin_uri}" -c "drop database if exists ${name}" \
         -c "create database ${name}"
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
        tail -n 40 "/tmp/${name}-resume.log"
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

# VACUUM: the tables vacuumed by the previous run are not vacuumed again, and
# the one in flight is
scenario_vacuum() {
    setup vacuum
    interrupt_index_phase

    catalog_edit "update vacuum_summary
                     set pid = ${stale_pid}, done_time_epoch = null,
                         duration = null
                   where tableoid = $(table_oid plain_t)"

    local before
    before=$(catalog_sql "select group_concat(tableoid || ':' || start_time_epoch)
                            from vacuum_summary
                           where tableoid <> $(table_oid plain_t)")

    resume
    check_complete

    test "$(catalog_sql "select group_concat(tableoid || ':' || start_time_epoch)
                           from vacuum_summary
                          where tableoid <> $(table_oid plain_t)")" = "${before}"
}

# indexes and constraints left in flight, or never started, by the previous
# run
scenario_constraints() {
    setup constraints
    interrupt_index_phase

    # the worker that queued the indexes of split_t was killed while
    # split_t_pad was being built, and the server finished building it
    catalog_edit "update s_table_parts_done set pid = ${stale_pid}
                   where tableoid = $(table_oid split_t);
                  update summary
                     set pid = ${stale_pid}, done_time_epoch = null,
                         duration = null
                   where indexoid = $(index_oid split_t_pad);
                  delete from s_table_indexes_done
                   where tableoid = $(table_oid split_t);
                  delete from summary
                   where conoid = $(constraint_oid split_t_pkey)"
    tgt "alter table split_t drop constraint split_t_pkey;
         create unique index split_t_pkey on split_t(id)"

    # the worker that claimed the constraints of con_a was killed before it
    # started them: the index is there, not the constraint
    catalog_edit "update s_table_indexes_done set pid = ${stale_pid}
                   where tableoid = $(table_oid con_a);
                  delete from summary
                   where conoid = $(constraint_oid con_a_pkey)"
    tgt "alter table con_a drop constraint con_a_pkey;
         create unique index con_a_pkey on con_a(id)"

    # the worker was killed during ALTER TABLE con_b ADD CONSTRAINT
    # con_b_r_key, and the server finished it
    catalog_edit "update summary
                     set pid = ${stale_pid}, done_time_epoch = null,
                         duration = null
                   where conoid = $(constraint_oid con_b_r_key);
                  delete from s_table_indexes_done
                   where tableoid = $(table_oid con_b)"

    # a catalog written by an older pgcopydb: no unique summary_conoid
    # index, and a second row for the constraint in flight
    catalog_edit "drop index summary_conoid;
                  insert into summary(pid, conoid, start_time_epoch, command)
                  select pid, conoid, start_time_epoch, command
                    from summary
                   where conoid = $(constraint_oid con_b_r_key)"

    resume
    check_complete

    test "$(catalog_sql "select count(*) from sqlite_master
                          where type = 'index'
                            and name = 'summary_conoid'")" = 1
    test "$(catalog_sql "select count(*) from summary
                          where conoid = $(constraint_oid con_b_r_key)")" = 1
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

# pg_dump was killed while it wrote the schema dump: the archive is
# truncated and its timing section is not done, and nothing after it ran
scenario_dump() {
    setup dump
    reset_after 2
    empty_target

    head -c 100 "${dir}/schema/schema.dump" > "${dir}/schema/schema.dump.part"
    mv "${dir}/schema/schema.dump.part" "${dir}/schema/schema.dump"

    resume
    check_complete
}

failed=""

for s in ${SCENARIOS:-split vacuum constraints postdata dump}; do
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
