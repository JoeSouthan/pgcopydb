#! /bin/bash

# --defer-validate-fks is recorded in the catalog setup, and a resume that
# changes the flag is refused.

set -x -e -o pipefail

for i in $(seq 1 30); do
    pgcopydb ping && break
    sleep 1
done

psql -d "${PGCOPYDB_SOURCE_PGURI}" -v ON_ERROR_STOP=1 -f fixture.sql

dbfile=/tmp/pgcopydb/schema/source.db

catalog_sql() {
    sqlite3 -readonly -init /dev/null -batch -noheader -list "${dbfile}" "$1"
}

# a filter-agnostic command registers the setup first: the flag is unclaimed
mkdir -p /tmp/pgcopydb/schema
pgcopydb stream sentinel setup --notice 0/0 0/0

test "$(catalog_sql 'select defer_validate_fks is null from setup')" = 1

# the first clone owning the flag records it
pgcopydb clone --resume --not-consistent --defer-validate-fks --notice

test "$(catalog_sql 'select defer_validate_fks from setup')" = 1

test "$(catalog_sql 'select count(*) from s_fk_constraint')" = 3
test "$(catalog_sql 'select count(*) from fk_validation_summary')" = 0

# the foreign keys are created NOT VALID by pgcopydb, not by pg_restore
q() {
    psql -AtX -d "${PGCOPYDB_TARGET_PGURI}" -c "$1"
}

test "$(q "select count(*) from pg_constraint where contype = 'f'")" = 3
test "$(q "select count(*) from pg_constraint where contype = 'f' and not convalidated")" = 3

q "select pg_get_constraintdef(oid) from pg_constraint where conname = 'Mixed Case FK'" |
    grep -q 'DEFERRABLE INITIALLY DEFERRED NOT VALID'

# the definitions are rendered with an empty search_path
test "$(catalog_sql "select constraintdef from s_fk_constraint where conname = 'child_parent_id_fkey'")" = \
    "FOREIGN KEY (parent_id) REFERENCES public.parent(id)"

test "$(catalog_sql 'select status, count(*) from fk_constraint_summary group by 1 order by 1')" = "created|2
source_not_valid|1"

if pgcopydb clone --resume --not-consistent --notice; then
    echo "resume without the flag must fail"
    exit 1
fi

pgcopydb clone --resume --not-consistent --defer-validate-fks --notice

# a command that does not own the flag neither refuses nor changes it
pgcopydb list tables --not-consistent --notice
test "$(catalog_sql 'select defer_validate_fks from setup')" = 1

# and refuses the option itself
if pgcopydb copy data --resume --not-consistent --defer-validate-fks \
    > /tmp/copy-data.out 2>&1; then
    echo "copy data must refuse --defer-validate-fks"
    exit 1
fi
grep "only supported by the clone command" /tmp/copy-data.out

# a catalog registered by a command that does not own the flag leaves it
# unclaimed, the first clone records it
dbfile=/tmp/other/schema/source.db

pgcopydb list tables --dir /tmp/other --not-consistent --notice
test "$(catalog_sql 'select defer_validate_fks is null from setup')" = 1

pgcopydb clone --dir /tmp/other --resume --drop-if-exists --not-consistent \
    --defer-validate-fks --notice
test "$(catalog_sql 'select defer_validate_fks from setup')" = 1

# a catalog written by an older pgcopydb, without the --defer-validate-fks
# column and tables, is upgraded when opened by any command
cp -a /tmp/pgcopydb /tmp/old

sqlite3 -init /dev/null -batch /tmp/old/schema/source.db <<'EOSQL'
drop table fk_validation_summary;
drop table fk_constraint_summary;
drop table s_fk_constraint;
alter table setup drop column defer_validate_fks;
EOSQL

dbfile=/tmp/old/schema/source.db

test "$(catalog_sql "select count(*) from pragma_table_info('setup')
                      where name = 'defer_validate_fks'")" = 0

pgcopydb stream sentinel get --dir /tmp/old --notice
pgcopydb list progress --dir /tmp/old --notice

test "$(catalog_sql 'select defer_validate_fks is null from setup')" = 1
test "$(catalog_sql "select count(*) from sqlite_master
                      where name in ('s_fk_constraint',
                                     'fk_constraint_summary',
                                     'fk_validation_summary')")" = 3

# a foreign key that already exists on the target, with the same definition,
# is recorded as created
admin_uri="${PGCOPYDB_TARGET_PGURI}"

recreate_target() {
    psql -d "${admin_uri}" -c "drop database if exists $1" \
         -c "create database $1"
    export PGCOPYDB_TARGET_PGURI="${admin_uri%/*}/$1"
}

recreate_target resumed

dbfile=/tmp/resumed/schema/source.db

pgcopydb dump schema --dir /tmp/resumed --not-consistent
pgcopydb restore pre-data --dir /tmp/resumed --resume --not-consistent
pgcopydb copy table-data --dir /tmp/resumed --resume --not-consistent
pgcopydb copy indexes --dir /tmp/resumed --resume --not-consistent
pgcopydb copy constraints --dir /tmp/resumed --resume --not-consistent

psql -d "${PGCOPYDB_TARGET_PGURI}" -v ON_ERROR_STOP=1 -c "
  alter table child add constraint child_parent_id_fkey
    foreign key (parent_id) references parent(id) not valid"

pgcopydb clone --dir /tmp/resumed --resume --not-consistent \
    --defer-validate-fks --notice

test "$(q "select count(*) from pg_constraint where contype = 'f'")" = 3
test "$(catalog_sql "select status from fk_constraint_summary
                      join s_fk_constraint on oid = conoid
                     where conname = 'child_parent_id_fkey'")" = created

# a foreign key to a table that is filtered out is skipped, the clone succeeds
recreate_target filtered

dbfile=/tmp/filtered/schema/source.db

cat > /tmp/filters.ini <<EOF
[exclude-table]
public.parent
EOF

pgcopydb clone --dir /tmp/filtered --not-consistent \
    --filters /tmp/filters.ini --defer-validate-fks --notice

test "$(catalog_sql 'select status, count(*) from fk_constraint_summary group by 1')" = "skipped_out_of_scope|3"

fks_on() {
    psql -AtX -d "${admin_uri%/*}/$1" -c \
        "select coalesce(string_agg(conname || ' ' || convalidated, ',' order by conname), '')
           from pg_constraint where contype = 'f'"
}

filtered_fks=$(fks_on filtered)

# the foreign keys out of scope are left to pg_restore and its filters: the
# target has the same foreign keys as a clone without the option
recreate_target filtered_without

pgcopydb clone --dir /tmp/filtered_without --not-consistent \
    --filters /tmp/filters.ini --notice

test "${filtered_fks}" = "$(fks_on filtered_without)"

# a foreign key declared on a partitioned table fails the post-data step, it
# is not lost silently
psql -d "${admin_uri}" -c "drop database if exists partitioned_source" \
     -c "create database partitioned_source"
psql -d "${admin_uri}" -c "drop database if exists partitioned_target" \
     -c "create database partitioned_target"

psql -d "${admin_uri%/*}/partitioned_source" -v ON_ERROR_STOP=1 <<'EOSQL'
create table parent(id int primary key);
create table events(id int, parent_id int, primary key (id))
  partition by hash (id);
create table events_0 partition of events for values with (modulus 2, remainder 0);
create table events_1 partition of events for values with (modulus 2, remainder 1);
alter table events add constraint events_parent_fk
  foreign key (parent_id) references parent(id);
insert into parent select i from generate_series(1, 10) i;
insert into events select i, 1 + (i % 10) from generate_series(1, 50) i;
EOSQL

if PGCOPYDB_SOURCE_PGURI="${admin_uri%/*}/partitioned_source" \
   PGCOPYDB_TARGET_PGURI="${admin_uri%/*}/partitioned_target" \
   pgcopydb clone --dir /tmp/partitioned --not-consistent \
       --defer-validate-fks --notice > /tmp/partitioned.out 2>&1; then
    cat /tmp/partitioned.out
    echo "clone must fail on a foreign key declared on a partitioned table"
    exit 1
fi

grep "Failed to create foreign key events_parent_fk on public.events" \
    /tmp/partitioned.out

# a foreign key that is not listed, here on a partitioned table without any
# partition, is left to pg_restore and exists on the target
psql -d "${admin_uri}" -c "drop database if exists unlisted_source" \
     -c "create database unlisted_source"
psql -d "${admin_uri}" -c "drop database if exists unlisted_target" \
     -c "create database unlisted_target"

psql -d "${admin_uri%/*}/unlisted_source" -v ON_ERROR_STOP=1 <<'EOSQL'
create table parent(id int primary key);
create table empty_events(id int, parent_id int, primary key (id))
  partition by hash (id);
alter table empty_events add constraint empty_events_parent_fk
  foreign key (parent_id) references parent(id);
insert into parent select i from generate_series(1, 10) i;
EOSQL

PGCOPYDB_SOURCE_PGURI="${admin_uri%/*}/unlisted_source" \
PGCOPYDB_TARGET_PGURI="${admin_uri%/*}/unlisted_target" \
    pgcopydb clone --dir /tmp/unlisted --not-consistent \
        --defer-validate-fks --notice

test "$(psql -AtX -d "${admin_uri%/*}/unlisted_target" -c \
    "select count(*) from pg_constraint where conname = 'empty_events_parent_fk'")" = 1
test "$(sqlite3 -readonly -init /dev/null -batch -noheader -list /tmp/unlisted/schema/source.db 'select count(*) from s_fk_constraint')" = 0
