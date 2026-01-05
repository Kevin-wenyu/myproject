select     
  e.*,     
  a.*     
from    
(select     
  current_setting('autovacuum_freeze_max_age')::int as v1,            -- 如果表的事务ID年龄大于该值, 即使未开启autovacuum也会强制触发FREEZE, 并告警Preventing Transaction ID Wraparound Failures    
  current_setting('autovacuum_multixact_freeze_max_age')::int as v2,  -- 如果表的并行事务ID年龄大于该值, 即使未开启autovacuum也会强制触发FREEZE, 并告警Preventing Transaction ID Wraparound Failures    
  current_setting('vacuum_freeze_min_age')::int as v3,                -- 手动或自动垃圾回收时, 如果记录的事务ID年龄大于该值, 将被FREEZE    
  current_setting('vacuum_multixact_freeze_min_age')::int as v4,      -- 手动或自动垃圾回收时, 如果记录的并行事务ID年龄大于该值, 将被FREEZE    
  current_setting('vacuum_freeze_table_age')::int as v5,              -- 手动垃圾回收时, 如果表的事务ID年龄大于该值, 将触发FREEZE. 该参数的上限值为 %95 autovacuum_freeze_max_age    
  current_setting('vacuum_multixact_freeze_table_age')::int as v6,    -- 手动垃圾回收时, 如果表的并行事务ID年龄大于该值, 将触发FREEZE. 该参数的上限值为 %95 autovacuum_multixact_freeze_max_age    
  current_setting('autovacuum_vacuum_cost_delay') as v7,              -- 自动垃圾回收时, 每轮回收周期后的一个休息时间, 主要防止垃圾回收太耗资源. -1 表示沿用vacuum_cost_delay的设置    
  current_setting('autovacuum_vacuum_cost_limit') as v8,              -- 自动垃圾回收时, 每轮回收周期设多大限制, 限制由vacuum_cost_page_hit,vacuum_cost_page_missvacuum_cost_page_dirty参数以及周期内的操作决定. -1 表示沿用vacuum_cost_limit的设置    
  current_setting('vacuum_cost_delay') as v9,                         -- 手动垃圾回收时, 每轮回收周期后的一个休息时间, 主要防止垃圾回收太耗资源.    
  current_setting('vacuum_cost_limit') as v10,                        -- 手动垃圾回收时, 每轮回收周期设多大限制, 限制由vacuum_cost_page_hit,vacuum_cost_page_missvacuum_cost_page_dirty参数以及周期内的操作决定.    
  current_setting('autovacuum') as autovacuum                         -- 是否开启自动垃圾回收    
) a,     
LATERAL (   -- LATERAL 允许你在这个SUBQUERY中直接引用前面的table, subquery中的column     
select     
pg_size_pretty(pg_total_relation_size(oid)) sz,   -- 表的大小(含TOAST, 索引)    
oid::regclass as reloid,    -- 表名(物化视图)    
relkind,                    -- r=表, m=物化视图    
coalesce(    
  least(    
    substring(reloptions::text, 'autovacuum_freeze_max_age=(\d+)')::int,     
    substring(reloptions::text, 'autovacuum_freeze_table_age=(\d+)')::int     
  ),    
  a.v1    
)    
-    
age(case when relfrozenxid::text::int<3 then null else relfrozenxid end)     
as remain_ages_xid,   -- 再产生多少个事务后, 自动垃圾回收会触发FREEZE, 起因为事务ID    
coalesce(    
  least(    
    substring(reloptions::text, 'autovacuum_multixact_freeze_max_age=(\d+)')::int,     
    substring(reloptions::text, 'autovacuum_multixact_freeze_table_age=(\d+)')::int     
  ),    
  a.v2    
)    
-    
age(case when relminmxid::text::int<3 then null else relminmxid end)     
as remain_ages_mxid,  -- 再产生多少个事务后, 自动垃圾回收会触发FREEZE, 起因为并发事务ID    
coalesce(    
  least(    
    substring(reloptions::text, 'autovacuum_freeze_min_age=(\d+)')::int    
  ),    
  a.v3    
) as xid_lower_to_minage,    -- 如果触发FREEZE, 该表的事务ID年龄会降到多少    
coalesce(    
  least(    
    substring(reloptions::text, 'autovacuum_multixact_freeze_min_age=(\d+)')::int    
  ),    
  a.v4    
) as mxid_lower_to_minage,   -- 如果触发FREEZE, 该表的并行事务ID年龄会降到多少    
case     
  when v5 <= age(case when relfrozenxid::text::int<3 then null else relfrozenxid end) then 'YES'    
  else 'NOT'    
end as vacuum_trigger_freeze1,    -- 如果手工执行VACUUM, 是否会触发FREEZE, 触发起因(事务ID年龄达到阈值)    
case     
  when v6 <= age(case when relminmxid::text::int<3 then null else relminmxid end) then 'YES'    
  else 'NOT'    
end as vacuum_trigger_freeze2,    -- 如果手工执行VACUUM, 是否会触发FREEZE, 触发起因(并行事务ID年龄达到阈值)    
reloptions                        -- 表级参数, 优先. 例如是否开启自动垃圾回收, autovacuum_freeze_max_age, autovacuum_freeze_table_age, autovacuum_multixact_freeze_max_age, autovacuum_multixact_freeze_table_age    
from pg_class     
  where relkind in ('r','m')    
) e     
order by     
  least(e.remain_ages_xid , e.remain_ages_mxid),  -- 排在越前, 越先触发自动FREEZE, 即风暴来临的预测    
  pg_total_relation_size(reloid) desc   -- 同样剩余年龄, 表越大, 排越前    
limit 10;    
