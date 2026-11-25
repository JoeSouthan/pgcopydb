create table parent(id int primary key);

create table child(
  id int primary key,
  parent_id int references parent(id)
);

create table "Order Items"(
  id int primary key,
  parent_id int,
  constraint "Mixed Case FK" foreign key (parent_id)
    references parent(id) deferrable initially deferred
);

create table legacy(id int primary key, parent_id int);

alter table legacy
  add constraint legacy_parent_fk foreign key (parent_id)
  references parent(id) not valid;

insert into parent select i from generate_series(1, 100) i;
insert into child select i, 1 + (i % 100) from generate_series(1, 300) i;
insert into "Order Items" select i, 1 + (i % 100) from generate_series(1, 300) i;
insert into legacy select i, 1 + (i % 100) from generate_series(1, 300) i;

-- the largest referencing table: its foreign key is validated first, and
-- holds the only validation worker (--index-jobs 1) for a while. A key with
-- a nondeterministic collation makes each row of the validation costly
-- (hashing computes an ICU sort key), so the window lasts without a huge
-- table to load and copy.
create collation case_insensitive
  (provider = icu, locale = 'und-u-ks-level2', deterministic = false);

create table big_parent(k text collate case_insensitive primary key);

create table big_child(
  id bigint primary key,
  parent_k text collate case_insensitive references big_parent(k)
);

insert into big_parent
     select repeat('abcdefgh', 8) || i from generate_series(1, 100) i;

insert into big_child
     select i, repeat('abcdefgh', 8) || (1 + i % 100)
       from generate_series(1, 10000000) i;

-- an orphan row, so that validating "Mixed Case FK" fails
set session_replication_role = replica;
insert into "Order Items" values (100001, 100000);
reset session_replication_role;
