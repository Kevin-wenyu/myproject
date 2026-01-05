SELECT 
	schemaname
	,relname
	,n_live_tup AS EstimatedCount 
	,last_autoanalyze
FROM pg_stat_all_tables 
ORDER BY n_live_tup DESC limit 10;
