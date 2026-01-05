\echo
\echo show all tables,views in every user schema:
SELECT c.oid as reloid,n.nspname as "Schema",
  c.relname as "Name",
  CASE c.relkind WHEN 'r' THEN 'table' WHEN 'v' THEN 'view' WHEN 'm' THEN 'materialized view' WHEN 'i' THEN 'index' WHEN 'S' THEN 'sequence' WHEN 's' THEN 'special' WHEN 'f' THEN 'foreign table' WHEN 'p' THEN 'partitioned table' WHEN 'I' THEN 'partitioned index' WHEN 'g' THEN 'global index' END as "Type",
  pg_catalog.pg_get_userbyid(c.relowner) as "Owner",
  pg_relation_filepath(c.oid) as relfilepath
FROM pg_catalog.pg_class c
     LEFT JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r','p','v','m','S','f','') 
           AND n.nspname <> 'pg_catalog'
                AND n.nspname <> 'information_schema'
                AND n.nspname <> 'sys'
                AND n.nspname <> 'sys_catalog'
                AND (c.oid not in (select reloid from sys_recyclebin))
      AND n.nspname !~ '^pg_toast'
      AND n.nspname not in ('anon','sysaudit','sysmac','perf','src_restrict','dbms_sql','xlog_record_read','plsql_profiler','sys_hm')
      AND pg_catalog.pg_get_userbyid(c.relowner) !='plprofiler'
ORDER BY Schema,Name;
