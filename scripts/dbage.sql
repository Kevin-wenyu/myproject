select datname,age(datfrozenxid) from pg_database order by 2 desc;
