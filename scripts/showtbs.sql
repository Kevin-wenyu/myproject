SELECT
  oid,
  spcname AS "Name",
  pg_catalog.pg_get_userbyid(spcowner) AS "Owner",
  pg_catalog.pg_tablespace_location(oid) AS "Location",
  pg_catalog.pg_size_pretty(pg_catalog.pg_tablespace_size(oid)) AS "Size",
  pg_catalog.array_to_string(spcacl, E'\n') AS "Access privileges",
  spcoptions AS "Options",
  pg_catalog.shobj_description(oid, 'pg_tablespace') AS "Description"
FROM pg_catalog.pg_tablespace
ORDER BY 1;
