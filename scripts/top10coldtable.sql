\echo list top10 cold table large than 100M:
select pg_size_pretty(pg_relation_size(relid)),* from pg_stat_all_tables where schemaname not in ('pg_toast','pg_catalog','information_schema','sysmac','sys') and pg_relation_size(relid)>=102400000 order by seq_scan+idx_scan, pg_relation_size(relid) desc limit 10;
