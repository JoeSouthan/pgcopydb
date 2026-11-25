-- $1::oid[] : referencing table OIDs from s_table
-- The scope is those tables plus their partitioned ancestors: s_table has no
-- partitioned table, and a foreign key declared on one is attached to it.
-- Partition FK clones (conparentid <> 0) are skipped: the top-level
-- constraint creates them again on the target.
WITH RECURSIVE scope(oid) AS (
    SELECT t.oid FROM unnest($1::oid[]) AS t(oid)
    UNION
    SELECT i.inhparent
      FROM pg_inherits i
      JOIN scope s ON s.oid = i.inhrelid
      JOIN pg_class p ON p.oid = i.inhparent AND p.relkind = 'p'
)
SELECT c.oid,
       c.conrelid,
       format('%I', c.conname) AS conname,
       n.nspname,
       r.relname,
       format('%I.%I', n.nspname, r.relname) AS qname,
       c.condeferrable,
       c.condeferred,
       c.convalidated,
       pg_get_constraintdef(c.oid),
       c.confrelid,
       c.confrelid IN (SELECT oid FROM scope) AS in_scope

  FROM pg_constraint c
  JOIN pg_class r ON r.oid = c.conrelid
  JOIN pg_namespace n ON n.oid = r.relnamespace

 WHERE c.contype = 'f'
   AND c.conparentid = 0
   AND c.conrelid IN (SELECT oid FROM scope)

 ORDER BY n.nspname, r.relname, c.conname;
