-- 03_export_csv.sql
-- Export source data to a pipe-delimited CSV (no header)

-- Update the output path to a writable directory on your system
\copy tbfundmergercontrol_src TO '/tmp/tbfundmergercontrol_src.csv' WITH (FORMAT csv, DELIMITER '|', HEADER false, QUOTE '"', ESCAPE '"', NULL '');
