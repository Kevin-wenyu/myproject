select schemaname,relname,n_live_tup,n_dead_tup,last_autovacuum,last_analyze from pg_stat_all_tables order by n_dead_tup desc limit 10;
