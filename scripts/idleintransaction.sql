\x
select 
*
from pg_stat_activity
 where usename not in ('system','esrep')
 and state like 'idle in transaction%'
 order by query_start;
