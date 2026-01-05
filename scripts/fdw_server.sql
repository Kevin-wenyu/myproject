SELECT s.srvname AS "Name",
  pg_catalog.pg_get_userbyid(s.srvowner) AS "Owner",
  f.fdwname AS "Foreign-data wrapper",
  pg_catalog.array_to_string(s.srvacl, E'\n') AS "Access privileges",
-- s.srvtype AS "Type",
-- s.srvversion AS "Version",
  CASE WHEN srvoptions IS NULL THEN '' ELSE '(' operator(pg_catalog.||) pg_catalog.array_to_string(ARRAY(SELECT   pg_catalog.quote_ident(option_name) operator(pg_catalog.||)  ' ' operator(pg_catalog.||) pg_catalog.quote_literal(option_value)  FROM   pg_catalog.pg_options_to_table(srvoptions)),  ', ') operator(pg_catalog.||) ')'   END AS "FDW options",
 d.description AS "Description"
FROM pg_catalog.pg_foreign_server s
     JOIN pg_catalog.pg_foreign_data_wrapper f ON f.oid=s.srvfdw
LEFT JOIN pg_catalog.pg_description d
       ON d.classoid = s.tableoid AND d.objoid = s.oid AND d.objsubid = 0
ORDER BY 1;
