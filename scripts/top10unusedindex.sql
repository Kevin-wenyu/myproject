\echo print top10 unused index larger than 10M:
\echo
select pg_size_pretty(pg_relation_size(indexrelid)),* 
from pg_stat_all_indexes where pg_relation_size(indexrelid)>=10240000 and idx_scan=0    
and schemaname not in ('pg_toast','pg_catalog') order by pg_relation_size(indexrelid) desc limit 10;
