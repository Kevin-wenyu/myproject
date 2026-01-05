with                                                 
a as (select sum(calls) s from sys_stat_statements),     
b as (select sum(calls) s from sys_stat_statements , pg_sleep(1))     
select     
b.s-a.s as qps         -- QPS    
from a,b;
