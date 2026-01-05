select schemaname,relname,n_live_tup,n_tup_ins from pg_stat_all_tables order by n_tup_ins desc limit 10;
