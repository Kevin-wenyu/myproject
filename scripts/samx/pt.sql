1. 活跃会话
最慢SQL
select pid,now()-query_start,substr(query,1,150),wait_event,wait_event_type from sys_stat_activity   where state = 'active' order by 2 desc ;


最多等待事件
select state,wait_event, count(*), wait_event_type from sys_stat_activity group by wait_event,state,wait_event_type order by count desc; \watch 1

wait_event由哪个SQL贡献：
select pid,(now()-query_start)run_time,substr(query,1,100) from sys_stat_activity where wait_event = 'lock_manager';

按照SQL和等待事件分组的count / SQL维度下最多等待事件:
select  substr(query,1,100),wait_event,wait_event_type,count(*) from sys_stat_activity where state = 'active' group by 1,2,3 order by 4 desc;

2. 累积执行事件
2.1 执行最长：
        select queryid,plans,total_plan_time,total_plan_time/(select sum(total_plan_time) from sys_stat_statements_all) as plan_percent,calls,total_exec_time,total_exec_time/(select sum(total_exec_time) from sys_stat_statements_all) as exec_percent,substr(query,1,100) from sys_stat_statements_all order by total_exec_time desc,total_plan_time desc limit 20; \watch 1

2.2 计划最长：
        select queryid,plans,total_plan_time,total_plan_time/(select sum(total_plan_time) from sys_stat_statements_all) as plan_percent,calls,total_exec_time,total_exec_time/(select sum(total_exec_time) from sys_stat_statements_all) as exec_percent,substr(query,1,100) from sys_stat_statements_all order by total_plan_time desc,total_exec_time desc limit 20; \watch 1

2.3 格式化执行最长：
select plans,round((total_plan_time/(plans+1)),2)mpt,round(total_plan_time,2)t_pt,calls,round((total_exec_time/(calls+1)),2)met,round(total_exec_time,2)t_et,substr(query,1,50) from sys_stat_statements_all order by total_exec_time desc,total_plan_time desc limit 20;


