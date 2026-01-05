select calls,userid::regrole,total_exec_time,total_exec_time/calls avg_exec_time_one_time,queryid,substr(query,1,1000) from sys_stat_statements
 where userid not in(select oid from pg_roles where rolname='esrep' or rolname='system') and calls >0
 and upper(query) not like 'COPY%'
 order by total_exec_time/calls desc
 limit 30;
