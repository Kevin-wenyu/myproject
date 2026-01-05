SELECT
    a.pid,
    a.datname,
    c.relname,
    a.phase,
    a.heap_blks_total blks_total,a.heap_blks_scanned blks_scanned,a.heap_blks_vacuumed blks_vacuumed,a.index_vacuum_count,
    round(a.heap_blks_scanned*100::numeric/a.heap_blks_total,2)||'%' AS "% scanned",
    round(a.heap_blks_vacuumed*100::numeric/a.heap_blks_total,2)||'%' AS "% vacuumed"
--    pg_size_pretty ( pg_table_size ( a.relid ) ) AS "tablesize",
--    pg_size_pretty ( pg_indexes_size ( a.relid ) ) AS "indexessize"
--    pg_get_userbyid ( c.relowner ) AS OWNER
FROM
--    pg_stat_activity p
    pg_stat_progress_vacuum a
    JOIN pg_class c ON c.oid = a.relid;
-- WHERE
--    upper(p.QUERY) LIKE '%VACUUM%';
