PG Bulkload Demo (2,000,000 rows)

Files
- `pg_bulkload_demo/01_schema.sql` creates the sequence, helper functions, and tables.
- `pg_bulkload_demo/02_generate_src.sql` generates 2,000,000 source rows.
- `pg_bulkload_demo/03_export_csv.sql` exports source data to a pipe-delimited CSV.
- `pg_bulkload_demo/pg_bulkload.ctl` mirrors the control file in the screenshot with PostgreSQL-equivalent functions.

Notes
- The control file uses placeholders `{INFILE}`, `{TABLENAME}`, `{LOGFILE}`, `{BADFILE}`, `{PARSE_BADFILE}`, `{DUPLICATE_BADFILE}`. Replace them before running.
- The filter function reads constants from session GUCs: `bulkload.batchno`, `bulkload.taskdate`.
- The helper functions are PostgreSQL equivalents of `systimestamp` and `to_number` usage.

Example run sequence
1. `psql -d yourdb -f pg_bulkload_demo/01_schema.sql`
2. `psql -d yourdb -f pg_bulkload_demo/02_generate_src.sql`
3. `psql -d yourdb -f pg_bulkload_demo/03_export_csv.sql`
4. Replace placeholders in `pg_bulkload_demo/pg_bulkload.ctl`.
5. Provide constants via GUCs and run pg_bulkload, for example:
   `PGOPTIONS='-c bulkload.batchno=20260205 -c bulkload.taskdate=20260205' time pg_bulkload -d yourdb pg_bulkload_demo/pg_bulkload.ctl`

Timing
- The last command prints the import time; record it as the 2,000,000-row load duration.
