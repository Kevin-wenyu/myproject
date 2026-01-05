SELECT um.srvname AS "Server",
  um.usename AS "User name",
 CASE WHEN umoptions IS NULL THEN '' ELSE   '(' operator(pg_catalog.||) pg_catalog.array_to_string(ARRAY(SELECT pg_catalog.quote_ident(option_name) operator(pg_catalog.||)  ' ' operator(pg_catalog.||)   pg_catalog.quote_literal(option_value)  FROM pg_catalog.pg_options_to_table(umoptions)),  ', ') operator(pg_catalog.||) ')'   END AS "FDW options"
FROM pg_catalog.pg_user_mappings um
ORDER BY 1, 2;
