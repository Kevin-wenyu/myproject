(select usename,datname,count(*) from pg_stat_activity where usename is not null and datname is not null  group by usename,datname order by 3,1,2)
union all
(select '总计','总计',count(*) from pg_stat_activity where usename is not null and datname is not null);
