select ts.nspname as schemaname,
        tbl.relname as tablename, 
       col.attname as columnname,
       se.sequenceowner,
       s.relname   as sequencename,
       se.max_value-se.last_value as value_left,se.data_type,se.start_value,se.min_value,se.max_value,se.increment_by,se.cycle,se.cache_size,se.last_value
from pg_class s
  join pg_namespace sn on sn.oid = s.relnamespace 
  join pg_depend d on d.refobjid = s.oid and d.refclassid='pg_class'::regclass 
  join pg_attrdef ad on ad.oid = d.objid and d.classid = 'pg_attrdef'::regclass
  join pg_attribute col on col.attrelid = ad.adrelid and col.attnum = ad.adnum
  join pg_class tbl on tbl.oid = ad.adrelid 
  join pg_namespace ts on ts.oid = tbl.relnamespace 
  join pg_sequences se on s.relname=se.sequencename
where s.relkind = 'S'
--  and s.relname = 'sequence_name'
  and d.deptype in ('a', 'n')
  and se.last_value is not null
  order by se.max_value-se.last_value limit 10;
