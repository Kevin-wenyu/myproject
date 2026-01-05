select u.usename,n.nspname,s.synname,s.refobjnspname,s.refobjname,s.syneditionable
 from sys_synonym s,pg_namespace n,pg_user u
where u.usesysid=s.synowner and s.synnamespace=n.oid;
