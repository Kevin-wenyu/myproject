\echo
select oid,nspname as schema,pg_get_userbyid(nspowner) as "owner",nspacl as "Access privileges" from pg_namespace where nspname not in ('pg_toast','pg_bitmapindex','pg_temp_1','pg_toast_temp_1','pg_catalog','information_schema','src_restrict','sysaudit','sysmac','anon','sys','sys_catalog','dbms_sql','xlog_record_read','plsql_profiler','sys_hm','perf') order by oid;
