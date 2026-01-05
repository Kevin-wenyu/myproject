select 
  wait_event,
  count(*)
 from pg_stat_activity
 where state='active' and wait_event is not null
 group by wait_event
 order by 2;
