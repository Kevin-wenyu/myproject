\echo please execute on standby database:
select pg_last_wal_receive_lsn(),pg_last_wal_replay_lsn(),pg_size_pretty(pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())) as replay_lag,pg_last_xact_replay_timestamp();
