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

for t in s_fk_constraint fk_constraint_summary fk_validation_summary; do
    test "$(catalog_sql "select count(*) from ${t}")" = 0
done

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
