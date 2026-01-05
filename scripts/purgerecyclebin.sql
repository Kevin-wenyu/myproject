\echo 
\echo list current object in recyclebin:
select recyclebin.oid,pg_catalog.pg_get_userbyid(pg_class.relowner) as owner,pg_namespace.nspname as schema,original_name,droptime,type from recyclebin,pg_class,pg_namespace where recyclebin.oid=pg_class.oid and pg_namespace.oid=pg_class.relnamespace;
purge recyclebin;
