\echo
\echo list granted tables exclude that owned:
select * from information_schema.table_privileges where grantor!=grantee and grantee not in ('sao','sso') and table_schema not in('information_schema','pg_catalog','sys','sys_catalog','sysmac') and table_name!='sys_stat_statements' order by 1,2,3,4,5;
