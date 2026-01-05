select indisvalid, indexrelid::regclass, indrelid::regclass, pg_get_indexdef(indexrelid) from pg_index where not indisvalid;
