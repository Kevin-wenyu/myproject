select 
 usename,
 datname,
 pid,
 wait_event,
 query_start,
 substr(query,1,1000) as query 
from pg_stat_activity
 where state='active'
 and usename not in ('esrep')
 order by query_start;
