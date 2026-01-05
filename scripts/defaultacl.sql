select pg_default_acl.oid,
        pg_authid.rolname as rolname,
        pg_namespace.nspname as schema,
        pg_default_acl.defaclobjtype,
        pg_default_acl.defaclacl
from pg_default_acl,pg_authid,pg_namespace
where 
pg_default_acl.defaclrole=pg_authid.oid
and
pg_default_acl.defaclnamespace=pg_namespace.oid
order by pg_namespace.nspname;
