SELECT
    a.pid,
    a.datname,
    c.relname,
    a.command,
    a.blocks_total,a.blocks_done,
    case when a.blocks_total=0 then null else round(a.blocks_done*100::numeric/a.blocks_total,2)||'%' end AS "% blocks" ,
    a.tuples_total,a.tuples_done,
    case when a.tuples_total=0 then null else round(a.tuples_done*100::numeric/a.tuples_total,2)||'%' end AS "% tuples" ,
    a.phase
FROM
    pg_stat_progress_create_index a
    JOIN pg_class c ON c.oid = a.relid;
