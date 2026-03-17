-- 01_schema.sql
-- Create sequence, helper functions, source table, and target table

BEGIN;

-- Sequence (Oracle: SQN_022REQUESTNO)
CREATE SEQUENCE IF NOT EXISTS sqn_022requestno
  AS bigint
  START WITH 1
  INCREMENT BY 1
  NO MINVALUE
  NO MAXVALUE
  CACHE 1000;

-- Oracle compatible helper for systimestamp formatted as yyyymmddhh24missff3
CREATE OR REPLACE FUNCTION fn_systimestamp_yyyymmddhh24missff3()
RETURNS text
LANGUAGE sql
AS $$
  SELECT to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS');
$$;

-- Oracle compatible helper for to_number with nullable text
CREATE OR REPLACE FUNCTION fn_to_number(p_text text)
RETURNS numeric
LANGUAGE sql
AS $$
  SELECT NULLIF(trim(p_text), '')::numeric;
$$;

-- Source table: matches the interface file columns only
CREATE TABLE IF NOT EXISTS tbfundmergercontrol_src
(
  vc_otherserialno        text,
  vc_requestno            text,
  vc_thirdtradeacco       text,
  vc_fundcode             text,
  vc_distributorcode      text,
  c_thirdbusinflag        text,
  vc_incomebelong         text,
  vc_targettradeacco      text,
  vc_targetdistributorcode text,
  vc_requestdate          text,
  vc_acceptdate           text,
  en_share                text,
  en_balance              text,
  c_custtype              text,
  vc_remark               text
);

-- Target table: includes extra columns (constants/functions/sequence)
CREATE TABLE IF NOT EXISTS tbfundmergercontrol
(
  vc_otherserialno        text,
  vc_requestno            text,
  vc_thirdtradeacco       text,
  vc_fundcode             text,
  vc_distributorcode      text,
  c_thirdbusinflag        text,
  vc_incomebelong         text,
  vc_targettradeacco      text,
  vc_targetdistributorcode text,
  vc_requestdate          text,
  vc_acceptdate           text,
  en_share                numeric,
  en_balance              numeric,
  c_custtype              text,
  vc_remark               text,
  vc_batchno              text,
  vc_taskdate             text,
  vc_opertime             text,
  l_serialno              bigint
);

-- Filter function for pg_bulkload (maps CSV fields to target row)
-- Uses session GUCs for batch/task values:
--   bulkload.batchno, bulkload.taskdate
CREATE OR REPLACE FUNCTION fn_tbfundmergercontrol_filter(
  p_vc_otherserialno text,
  p_vc_requestno text,
  p_vc_thirdtradeacco text,
  p_vc_fundcode text,
  p_vc_distributorcode text,
  p_c_thirdbusinflag text,
  p_vc_incomebelong text,
  p_vc_targettradeacco text,
  p_vc_targetdistributorcode text,
  p_vc_requestdate text,
  p_vc_acceptdate text,
  p_en_share text,
  p_en_balance text,
  p_c_custtype text,
  p_vc_remark text
)
RETURNS tbfundmergercontrol
LANGUAGE sql
AS $$
  SELECT
    p_vc_otherserialno,
    p_vc_requestno,
    p_vc_thirdtradeacco,
    p_vc_fundcode,
    p_vc_distributorcode,
    p_c_thirdbusinflag,
    p_vc_incomebelong,
    p_vc_targettradeacco,
    p_vc_targetdistributorcode,
    p_vc_requestdate,
    p_vc_acceptdate,
    CASE WHEN p_c_thirdbusinflag = '022' THEN 0 ELSE fn_to_number(p_en_share) END,
    CASE WHEN p_c_thirdbusinflag != '022' THEN 0 ELSE fn_to_number(p_en_balance) END,
    p_c_custtype,
    p_vc_remark,
    COALESCE(current_setting('bulkload.batchno', true), '{BATCHNO}'),
    COALESCE(current_setting('bulkload.taskdate', true), '{TASKDATE}'),
    fn_systimestamp_yyyymmddhh24missff3(),
    nextval('sqn_022requestno')
$$;

COMMIT;
