--
-- Tables with many unique constraints: the CREATE INDEX workers build each
-- table's constraints one after the other while they iterate over the
-- table's indexes in the source catalog, and record each constraint in the
-- summary table as they go.
--
do $$
declare
    t int;
    c int;
    cols text;
begin
    for t in 1..8
    loop
        cols := 'id bigint primary key';

        for c in 1..24
        loop
            cols := cols || format(', c%s bigint', c);
        end loop;

        execute format('create table items_%s(%s)', t, cols);

        for c in 1..24
        loop
            execute format('alter table items_%s add constraint items_%s_c%s_key unique (c%s)',
                           t, t, c, c);
        end loop;

        execute format('insert into items_%s select i %s from generate_series(1, 20000) as i',
                       t,
                       (select string_agg(format(', i * 100 + %s', n), '')
                          from generate_series(1, 24) as n));
    end loop;
end
$$;

-- a stream of small transactions while the clone builds the constraints
create table ticks(id bigserial primary key, at timestamptz default now());

--
-- An exclusion constraint is created with ALTER TABLE ... ADD CONSTRAINT
-- EXCLUDE, which builds its index there: with a few million rows that takes
-- long enough for the follow process to commit to the catalog in the
-- meantime, every time.
--
create table slots(id bigint primary key, v bigint, exclude using btree (v with =));

insert into slots select i, i from generate_series(1, 3000000) as i;
