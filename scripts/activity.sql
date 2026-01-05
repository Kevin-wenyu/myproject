select 
 usename,
 datname,
 pid,
 state,
-- wait_event,
 backend_start,
 query_start,
 substr(query,1,1000) as query 
from pg_stat_activity
 where usename not in ('system','esrep')
 order by query_start desc nulls last;
