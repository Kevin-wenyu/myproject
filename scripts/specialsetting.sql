SELECT nvl(db.datname,'all') dbname,nvl(usr.usename,'all') username,conf.setconfig
FROM pg_db_role_setting conf
LEFT JOIN pg_database db
ON conf.setdatabase=db.oid
LEFT JOIN pg_user usr
ON conf.setrole=usr.usesysid;
