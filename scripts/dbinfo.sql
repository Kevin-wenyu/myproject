select
    d.datname,
    d.oid as datoid,
    pg_catalog.pg_get_userbyid(d.datdba) as "owner",
    d.datdba as useroid,
    pg_catalog.pg_encoding_to_char(d.encoding) as "encoding",
    d.datcollate as "collate",
--    pg_database.datctype as "ctype",
    pg_catalog.array_to_string(d.datacl, E'\n') AS "Access privileges",
    pg_size_pretty (pg_database_size(d.datname)) as size,
    t.spcname as "Tablespace",
    pg_catalog.shobj_description(d.oid, 'pg_database') as "Description"
FROM pg_catalog.pg_database d
  JOIN pg_catalog.pg_tablespace t on d.dattablespace = t.oid
    order by pg_database_size(d.datname),datoid;
