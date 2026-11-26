-- Post-data objects that pgcopydb does not track itself: triggers, extended
-- statistics, a partitioned index, and foreign keys (created by pgcopydb
-- with --defer-validate-fks).
create function touch() returns trigger language plpgsql
as $$ begin return new; end $$;

create table parent(id integer primary key, v text);
insert into parent select g, 'v' || g from generate_series(1, 1000) g;
create trigger parent_touch before update on parent
  for each row execute function touch();
create statistics parent_stats (ndistinct) on id, v from parent;

create table child(id integer primary key, parent_id integer references parent(id));
insert into child select g, g from generate_series(1, 1000) g;
create index child_parent_id on child(parent_id);
create trigger child_touch before update on child
  for each row execute function touch();

-- copied in several parts
create table split_t(id integer primary key, pad text);
insert into split_t select g, repeat('x', 100) from generate_series(1, 5000) g;
create index split_t_pad on split_t(pad);

-- a primary key and a unique constraint, each built on its own index
create table con_a(id integer primary key, r integer);
insert into con_a select g, g from generate_series(1, 100) g;

create table con_b(id integer primary key, r integer,
                   constraint con_b_r_key unique (r));
insert into con_b select g, g from generate_series(1, 100) g;

-- no index: queued for VACUUM by the COPY worker
create table plain_t(id integer, v text);
insert into plain_t select g, 'v' || g from generate_series(1, 1000) g;

create table pt(id integer, created date, primary key (id, created))
  partition by range (created);
create table pt_2026 partition of pt
  for values from ('2026-01-01') to ('2027-01-01');
create index pt_created on pt(created);
insert into pt
     select g, date '2026-01-01' + (g % 300) from generate_series(1, 1000) g;
