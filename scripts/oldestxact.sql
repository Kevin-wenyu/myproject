\x
select pid,datname,usename,application_name,client_addr,client_port,backend_start,xact_start,
query_start,state_change,wait_event,backend_xid,backend_xmin,now()-xact_start as old_ts,
txid_current()-least(backend_xid::text::int8,backend_xmin::text::int8) as old_xacts,state,backend_type,
query
from pg_stat_activity 
order by least(backend_xid::text::int8,backend_xmin::text::int8),xact_start limit 1;
