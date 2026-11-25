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
