\echo
\echo list idle pid before 15 days:
select pid,datname,xact_start,query_start,query 
 from
  pg_stat_activity
 where
  state like 'idle%'
  and usename not in ('esrep','system')
  and query_start<(select now()-interval '15 day') 
 order by query_start;

\echo
\echo kill idle pid before 15 days:
select pg_terminate_backend(pid)
 from
  pg_stat_activity
 where
  state like 'idle%'
  and usename not in ('esrep','system')
  and query_start<(select now()-interval '15 day') ;
