-- 02_generate_src.sql
-- Generate 2,000,000 rows of source data

INSERT INTO tbfundmergercontrol_src
(
  vc_otherserialno,
  vc_requestno,
  vc_thirdtradeacco,
  vc_fundcode,
  vc_distributorcode,
  c_thirdbusinflag,
  vc_incomebelong,
  vc_targettradeacco,
  vc_targetdistributorcode,
  vc_requestdate,
  vc_acceptdate,
  en_share,
  en_balance,
  c_custtype,
  vc_remark
)
SELECT
  'OSN' || gs::text,
  'REQ' || lpad(gs::text, 12, '0'),
  'TA'  || lpad((gs % 1000000)::text, 12, '0'),
  'FC'  || lpad((gs % 9999)::text, 6, '0'),
  'D'   || lpad((gs % 9999)::text, 6, '0'),
  CASE WHEN gs % 5 = 0 THEN '022' ELSE '023' END,
  CASE WHEN gs % 2 = 0 THEN 'Y' ELSE 'N' END,
  'TT'  || lpad((gs % 1000000)::text, 12, '0'),
  'TD'  || lpad((gs % 9999)::text, 6, '0'),
  to_char(current_date - (gs % 365), 'YYYYMMDD'),
  to_char(clock_timestamp() - (gs % 86400) * interval '1 second', 'YYYYMMDDHH24MISS'),
  to_char((random() * 100000)::numeric(18,2)),
  to_char((random() * 100000)::numeric(18,2)),
  CASE WHEN gs % 2 = 0 THEN '1' ELSE '2' END,
  'remark-' || gs::text
FROM generate_series(1, 2000000) AS gs;
