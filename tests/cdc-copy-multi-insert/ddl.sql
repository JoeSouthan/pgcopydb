-- the apply waits for a row in tx to know the changes before it are applied
create table tx (id integer primary key);

create table t_copy (id integer primary key, v text);
create table t_ins (id integer primary key, v text);

create table p_copy (id integer primary key, v text) partition by range (id);
create table p_copy_a partition of p_copy for values from (minvalue) to (2501);
create table p_copy_b partition of p_copy for values from (2501) to (maxvalue);
