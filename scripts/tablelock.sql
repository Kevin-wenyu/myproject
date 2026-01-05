select
    pg_class.relname as table,
    pg_database.datname as database,
    pg_locks.pid,
    mode,
    granted
from
    pg_locks,
    pg_class,
    pg_database
where
    pg_locks.relation = pg_class.oid
    and pg_locks.database = pg_database.oid
    and pg_class.reltype !=0
    and pg_class.relowner not in 
    (select usesysid from pg_user
         where
         usename in ('sao','sso','system'))
order by
    pg_class.relname,pg_database.datname,mode;

