\echo 
select pg_walfile_name_offset(pg_current_wal_insert_lsn()) as "pg_current_walfile_name,offset",pg_current_wal_lsn(),pg_current_wal_flush_lsn(),pg_current_wal_insert_lsn();
