with tmp_file as (
select to_char(date_trunc('day',(pg_stat_file(file)).modification),'yyyymmdd') as day_id, 
date_part('hour',(pg_stat_file(t1.file)).modification) as last_update_time,
date_part('minute',(pg_stat_file(t1.file)).modification) as last_update_per_min
from (select dir||'/'||pg_ls_dir(t0.dir) as file,
pg_ls_dir(t0.dir) as file_ls
from ( select setting||'/sys_wal' as dir from pg_settings where name='data_directory'
) t0
) t1 
--where 1=1 and t1.file_ls not in ('archive_status','.history')
where 1=1 and t1.file_ls not in ('archive_status','._t_total_non_archive') and t1.file_ls not like '%.history' and t1.file_ls not like '%.backup'
order by (pg_stat_file(file)).modification desc
)
select hour,第0_10分钟+第10_20分钟+第20_30分钟+第30_40分钟+第40_50分钟+第50_60分钟 as 总计归档数,第0_10分钟,第10_20分钟,第20_30分钟,第30_40分钟,第40_50分钟,第50_60分钟
from
(
select day_id||'-'||lpad(last_update_time,2,'0') as hour,
sum(case when last_update_per_min >=0 and last_update_per_min <=10 then 1 else 0 end) as 第0_10分钟,
sum(case when last_update_per_min >10 and last_update_per_min <=20 then 1 else 0 end) as 第10_20分钟,
sum(case when last_update_per_min >20 and last_update_per_min <=30 then 1 else 0 end) as 第20_30分钟,
sum(case when last_update_per_min >30 and last_update_per_min <=40 then 1 else 0 end) as 第30_40分钟,
sum(case when last_update_per_min >40 and last_update_per_min <=50 then 1 else 0 end) as 第40_50分钟,
sum(case when last_update_per_min >50 and last_update_per_min <=60 then 1 else 0 end) as 第50_60分钟
from tmp_file tf
where 1=1
group by day_id,last_update_time
order by day_id desc,last_update_time desc limit 100
) t;
