-- Copyright Kevin Ge, Kingbase Industrial Technical Service, all right reserved.
--
-- NAME
--     healthcheck_v8r6.sql This is a single SQL-only script for gathering performance and configuration data from Kingbase databases.
--     And another SQL script available for analyzing and generating detailed HTML reports from the collected data. Yes, everything SQL-Only!, 
--     leveraging the features of psql-The command-line utility of Kingbase
--     Supported Versions : Kingbase V8R6
--
-- DESCRIPTION
--     Database healthcheck, only for Kingbase(Including Streaming) v8r6.
--     Successfully tested on Linux and Windows.
--     Please test it before attempting to run it in production.
--     For educational purposes only, and is not supported by Kingbase Support.
--
-- USAGE
--     psql <connection_parameters_if_any> -X -f healthcheck_v8r6.sql
--
-- Example:
-- for db in `ksql -Usystem -dtest --pset=pager=off -t -A -q -c 'select datname from sys_database where datname not in ($$template0$$, $$template1$$)'`; do ksql -Usystem -d$db -X -q -f healthcheck.sql; done
--
-- MODIFIED   VERSION   (YYYY/MM/DD)                                                                        
-- -------------------------------------------------------------------------------------------------------------
-- Kevin      1.0       2023/02/01 - First Edition
-- Kevin      1.1       2023/03/10  Add Wal switching
----------------------------------------------------------------------------------------------------------------

SET max_parallel_workers_per_gather = 0;

select to_char(now(),'YYYYMMDDHH24MISS') as "spooltime",current_database() as "datname" \gset

\echo
\echo '+---------------------------------------------------------------------+'
\echo '|                   Kingbase database Health Check                    |'
\echo '+---------------------------------------------------------------------+'
\echo '|        Copyright (c) 2023 Kevin Ge, All Rights Reserved.            |'
\echo '+---------------------------------------------------------------------+'
\echo '|This script must be run as a user with SYSTEM privileges.            |'
\echo '|This script applies to Kingbase V8R6, including Streaming.           |'
\echo '|Please test it before attempting to run it in your production.       |'
\echo '|The process can take several minutes to complete.                    |'
\echo '|For educational purposes only, not supported by Kingbase Support.    |'
\echo '|                                                                     |'
\echo '|Usage:                                                               |'
\echo '|  ksql <connection_parameters_if_any> -X -q -f healthcheck_v8r6.sql  |'
\echo '|  for db in `ksql -Usystem -dtest --pset=pager=off -t -A -q -c 'select datname from sys_database where datname not in ($$template0$$, $$template1$$)'`; do ksql -Usystem -d$db -X -q -f healthcheck.sql; done |'
\echo '+---------------------------------------------------------------------+'
\echo 
\echo 
\echo '>>> Creating ':datname' database report...'
\echo

-- ==============================================================================
--                            Script Settings
-- ==============================================================================
\set internalVersion V1.1
\r
\pset format html
\pset footer off
\pset tableattr 'class="thidden"'
\o 'Healthcheck_':datname'_':spooltime'.html'

-- ==============================================================================
--                            Html Style Settings
-- ==============================================================================

\qecho <!DOCTYPE html>
\qecho <html><meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
\qecho <style type="text/css">
\qecho table, th, td { border: 1px solid black; border-collapse: collapse; border-spacing: 0; padding: 2px 4px 2px 4px;}
\qecho th {background-color: #d2f2ff;cursor: pointer; }
\qecho tr:nth-child(even) {background-color: #eef8ff}
\qecho tr:hover { background-color: #FFFFCA}
\qecho h2 { scroll-margin-left: 2em;} /*keep the scroll left*/
\qecho h3 { scroll-margin-left: 2em;} /*keep the scroll left*/
\qecho caption { font-size: larger }
\qecho ol { width: fit-content;}
\qecho ul { width: fit-content;}
\qecho .warn { font-weight:bold; background-color: #FAA }
\qecho .high { border: 5px solid red;font-weight:bold}
\qecho .thidden tr td:first-child {color:blue;}
\qecho footer { text-align: center; padding: 3px; background-color:#d2f2ff}
\qecho </style>


-- ==============================================================================
--                          Report Header Information
-- ==============================================================================
\qecho <h1>
\qecho <div style="background:red;width:100%;">
\qecho <font size="+2" color="white" face="Lucida Console"><b>KINGBASE</b><sup>&reg;</sup></font>
\qecho <font size="+1" color="white" face="Arial"> Database Health Check Snapshot</font>
\qecho </div>
\qecho </h1>

-- ==============================================================================
--                          Main Report Information
-- ==============================================================================
\qecho <h2 id="topics"><font size="+2" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Main Report Information</b></font></h2>
\qecho <ol>
\qecho <li><a href="#BI">Basic Information</a></li>
\qecho <li><a href="#CI">Connection Information</a></li>
\qecho <li><a href="#SS">Storage Statistics</a></li>
\qecho <li><a href="#WAI">Wal / Archive Information</a></li>
\qecho <li><a href="#URSD">Users / Roles / Schemas Details</a></li>
\qecho <li><a href="#SI">Security Information</a></li>
\qecho <li><a href="#OS">Objects Statistics</a></li>
\qecho <li><a href="#SR">Streaming Replications</a></li>
\qecho <li><a href="#PS">Performance Statistics</a></li>
\qecho <li><a href="#LI">Locks Information</a></li>
\qecho <li><a href="#ED">Extensions Details</a></li>
\qecho <li><a href="#VI">Vacuum Information</a></li>
\qecho <li><a href="#BD">Backup Details</a></li>
\qecho <li><a href="#JSI">Job / Schedules Information</a></li>
\qecho <li><a href="#PSD">Parameters / Settings Details</a></li>
\qecho <li><a href="#findings">Findings</a></li>
\qecho </ol>
\qecho <a href="#topics">Back to Top</a>


-- ==============================================================================
--                               1. Basic Information
-- ==============================================================================
\qecho <h3 id="BI"><font size="+2" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Basic Information</b></font></h3>
\qecho <ul>
\qecho <li><a href="#1KII">Kingbase Installed Info</a></li>
\qecho <li><a href="#1LI">License Info</a></li>
\qecho <li><a href="#1DI">Database Info</a></li>
\qecho <li><a href="#1TI">Timezone Info</a></li>
\qecho </ul>
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                Kingbase Installed Info
-- -------------------------------------------------------------------------
\qecho <h3 id="1KII"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Kingbase Installed Info</b></font></h3>
\echo 'Query Kingbase installed info ...'
SELECT * FROM sys_config ;

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#BI">Back to Basic Information</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                License info
-- -------------------------------------------------------------------------
\qecho <h3 id="1LI"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>License Info</b></font></h3>
\echo 'Query License info ...'
SELECT current_timestamp,
       current_user,
       current_database(),
       now() - pg_postmaster_start_time() "uptime",
       pg_postmaster_start_time() "server_start_time",
       version(),
       (case when sys_is_in_recovery()='f' then 'Primary' else 'Standby' end ) as  primary_or_standby,
       inet_client_addr(),
       inet_server_addr(),
       pg_conf_load_time(),
       get_license_validdays(),
       get_license_paralleldump(),
       get_license_rman(),
       get_license_safemac(),
CASE WHEN pg_is_in_recovery() 
THEN pg_last_wal_receive_lsn() 
ELSE pg_current_wal_lsn() 
END;

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#BI">Back to Basic Information</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                Database info
-- -------------------------------------------------------------------------
\qecho <h3 id="1DI"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Database Info</b></font></h3>
\echo 'Query Database info ...'
SELECT d.datname as "Name",
       sys_get_userbyid(d.datdba) as "Owner",
       sys_encoding_to_char(d.encoding) as "Encoding",
       d.datcollate as "Collate",
       d.datctype as "Ctype",
       array_to_string(d.datacl, E'\n') AS "Access privileges",
       CASE WHEN has_database_privilege(d.datname, 'CONNECT')
            THEN sys_size_pretty(sys_database_size(d.datname))
            ELSE 'No Access'
       END as "Size",
       t.spcname as "Tablespace",
       shobj_description(d.oid, 'sys_database') as "Description",
       age(datfrozenxid)          "Age",
       2 ^ 31 - age(datfrozenxid) "Remain Age"
FROM sys_database d
  JOIN sys_tablespace t on d.dattablespace = t.oid
ORDER BY 1;

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#BI">Back to Basic Information</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>


-- -------------------------------------------------------------------------
--                                Timezone Info
-- -------------------------------------------------------------------------
\qecho <h3 id="1TI"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Timezone Info</b></font></h3>
\echo 'Query Timezone info ...'
select name,setting,short_desc,boot_val from sys_settings where name='TimeZone';

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#BI">Back to Basic Information</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- ==============================================================================
--                               2. Connection Information
-- ==============================================================================
\qecho <h3 id="CI"><font size="+2" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Connection Information</b></font></h3>
\qecho <ul>
\qecho <li><a href="#2AS">Active Session</a></li>
\qecho <li><a href="#2RC">Remaining Connections</a></li>
\qecho <li><a href="#2BS">Blocking Session</a></li>
\qecho <li><a href="#2IMS">Index Maintains session</a></li>
\qecho </ul>
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                 Active Session
-- -------------------------------------------------------------------------
\qecho <h3 id="2AS"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Active Session</b></font></h3>
\echo 'Query active session ...'
select pid as process_id,
usename as username,
datname as database_name,
client_addr as client_address,
application_name,
backend_start,
state,
state_change,query
from sys_stat_activity
where state is not null and state<>'idle';
\qecho <hr align="left" size="1" color="Gray" width="20%" />
-- User limits
\qecho <b>Display user connect limits</b>
select a.rolname,a.rolconnlimit,b.connects from sys_authid a,(select usename,count(*) connects from sys_stat_activity group by usename) b where a.rolname=b.usename order by b.connects desc;
\qecho <hr align="left" size="1" color="Gray" width="20%" />
-- database limits
\qecho <b>Display database connect limits</b>
select a.datname, a.datconnlimit, b.connects from sys_database a,(select datname,count(*) connects from sys_stat_activity group by datname) b where a.datname=b.datname order by b.connects desc;
\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#CI">Back to Connection Information</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>


-- -------------------------------------------------------------------------
--                                 Remaining Connections
-- -------------------------------------------------------------------------
\qecho <h3 id="2RC"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Remaining Connections</b></font></h3>
\echo 'Query Remaining connections ...'
select max_conn,used,res_for_super,max_conn-used-res_for_super res_for_normal from (select count(*) used from pg_stat_activity) t1,(select setting::int res_for_super from pg_settings where name=$$superuser_reserved_connections$$) t2,(select setting::int max_conn from pg_settings where name=$$max_connections$$) t3;

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#CI">Back to Connection Information</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                 Blocking Session
-- -------------------------------------------------------------------------
\qecho <h3 id="2BS"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Blocking Session</b></font></h3>
\echo 'Query Blocking session ...'
SELECT blocked_locks.pid  AS blocked_pid,
       blocked_activity.usename  AS blocked_user,
       blocked_activity.client_addr as blocked_client_addr,
       blocked_activity.client_hostname as blocked_client_hostname,
       blocked_activity.application_name as blocked_application_name,
       blocked_activity.wait_event_type as blocked_wait_event_type,
       blocked_activity.wait_event as blocked_wait_event,
       blocked_activity.query   AS blocked_statement,
       blocked_activity.xact_start AS blocked_xact_start,
       blocking_locks.pid  AS blocking_pid,
       blocking_activity.usename AS blocking_user,
       blocking_activity.client_addr as blocking_client_addr,
       blocking_activity.client_hostname as blocking_client_hostname,
       blocking_activity.application_name as blocking_application_name,
       blocking_activity.wait_event_type as blocking_wait_event_type,
       blocking_activity.wait_event as blocking_wait_event,
       blocking_activity.query AS current_statement_in_blocking_process,
       blocking_activity.xact_start AS blocking_xact_start
FROM  pg_catalog.pg_locks   blocked_locks
   JOIN pg_catalog.pg_stat_activity blocked_activity ON blocked_activity.pid = blocked_locks.pid
   JOIN pg_catalog.pg_locks  blocking_locks 
        ON blocking_locks.locktype = blocked_locks.locktype
        AND blocking_locks.DATABASE IS NOT DISTINCT FROM blocked_locks.DATABASE
        AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation
        AND blocking_locks.page IS NOT DISTINCT FROM blocked_locks.page
        AND blocking_locks.tuple IS NOT DISTINCT FROM blocked_locks.tuple
        AND blocking_locks.virtualxid IS NOT DISTINCT FROM blocked_locks.virtualxid
        AND blocking_locks.transactionid IS NOT DISTINCT FROM blocked_locks.transactionid
        AND blocking_locks.classid IS NOT DISTINCT FROM blocked_locks.classid
        AND blocking_locks.objid IS NOT DISTINCT FROM blocked_locks.objid
        AND blocking_locks.objsubid IS NOT DISTINCT FROM blocked_locks.objsubid
        AND blocking_locks.pid != blocked_locks.pid
   JOIN pg_catalog.pg_stat_activity blocking_activity ON blocking_activity.pid = blocking_locks.pid
WHERE NOT blocked_locks.granted ORDER BY blocked_activity.pid ;

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#CI">Back to Connection Information</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>


-- -------------------------------------------------------------------------
--                                 Index Maintains session
-- -------------------------------------------------------------------------
\qecho <h3 id="2IMS"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Index Maintains session</b></font></h3>
\echo 'Query Index Maintains session ...'
SELECT
	pid,
	datname,
	command,
	phase,
	tuples_total,
	tuples_done,
	partitions_total,
	partitions_done
FROM
	pg_stat_progress_create_index;

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#CI">Back to Connection Information</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>


-- ==============================================================================
--                               3. Storage Statistics
-- ==============================================================================
\qecho <h3 id="SS"><font size="+2" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Storage Statistics</b></font></h3>
\qecho <ul>
\qecho <li><a href="#3TD">Tablespace Details</a></li>
\qecho </ul>
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                Tablespace details
-- -------------------------------------------------------------------------
\qecho <h3 id="3TD"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Tablespace Details</b></font></h3>
\echo 'Query Tablespace details ...'
--select spcname,pg_tablespace_location(oid),pg_size_pretty(pg_tablespace_size(oid)) from pg_tablespace order by pg_tablespace_size(oid) desc;

SELECT oid,spcname AS "Name",
  sys_get_userbyid(spcowner) AS "Owner",
  sys_tablespace_location(oid) AS "Location",
  array_to_string(spcacl, E'\n') AS "Access privileges",
  spcoptions AS "Options",
  sys_size_pretty(sys_tablespace_size(oid)) AS "Size",
  shobj_description(oid, 'sys_tablespace') AS "Description"
FROM sys_tablespace
ORDER BY 1;

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#SS">Back to Storage Statistics</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- ==============================================================================
--                               4. Wal / Archive Information
-- ==============================================================================
\qecho <h3 id="WAI"><font size="+2" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Wal / Archive Information</b></font></h3>
\qecho <ul>
\qecho <li><a href="#4WSR">Wal Switch Rate</a></li>
\qecho <li><a href="#4AS">Archive Settings</a></li>
\qecho <li><a href="#4APS">Archiver Process Status</a></li>
\qecho <li><a href="#4ASS">Archiver Status</a></li>
\qecho </ul>
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                 Wal Switch Rate
-- -------------------------------------------------------------------------
\qecho <h3 id="4WSR"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Wal Switch Rate</b></font></h3>
\echo 'Query Wal Switch Rate ...'
with tmp_file as (
    select t1.file,
           (sys_stat_file(t1.file)).size as size,
           (sys_stat_file(t1.file)).access as access,
           (sys_stat_file(t1.file)).modification as last_update_time,
           (sys_stat_file(t1.file)).isdir as isdir
    from (select dir||'/'||sys_ls_dir(t0.dir) as file
          from (select setting||'/sys_wal'::text as dir from sys_settings where name='data_directory') t0
         ) t1 
)
select to_char(date_trunc('day',tf0.last_update_time),'yyyymmdd') as day_id,
       sum(case when date_part('hour',tf0.last_update_time) >=0 and date_part('hour',tf0.last_update_time) <24 then 1 else 0 end) as wal_count,
       sum(case when date_part('hour',tf0.last_update_time) =0 then 1 else 0 end) as H00,
       sum(case when date_part('hour',tf0.last_update_time) =1 then 1 else 0 end) as H01,
       sum(case when date_part('hour',tf0.last_update_time) =2 then 1 else 0 end) as H02,
       sum(case when date_part('hour',tf0.last_update_time) =3 then 1 else 0 end) as H03,
       sum(case when date_part('hour',tf0.last_update_time) =4 then 1 else 0 end) as H04,
       sum(case when date_part('hour',tf0.last_update_time) =5 then 1 else 0 end) as H05,
       sum(case when date_part('hour',tf0.last_update_time) =6 then 1 else 0 end) as H06,
       sum(case when date_part('hour',tf0.last_update_time) =7 then 1 else 0 end) as H07,
       sum(case when date_part('hour',tf0.last_update_time) =8 then 1 else 0 end) as H08,
       sum(case when date_part('hour',tf0.last_update_time) =9 then 1 else 0 end) as H09,
       sum(case when date_part('hour',tf0.last_update_time) =10 then 1 else 0 end) as H10,
       sum(case when date_part('hour',tf0.last_update_time) =11 then 1 else 0 end) as H11,
       sum(case when date_part('hour',tf0.last_update_time) =12 then 1 else 0 end) as H12,
       sum(case when date_part('hour',tf0.last_update_time) =13 then 1 else 0 end) as H13,
       sum(case when date_part('hour',tf0.last_update_time) =14 then 1 else 0 end) as H14,
       sum(case when date_part('hour',tf0.last_update_time) =15 then 1 else 0 end) as H15,
       sum(case when date_part('hour',tf0.last_update_time) =16 then 1 else 0 end) as H16,
       sum(case when date_part('hour',tf0.last_update_time) =17 then 1 else 0 end) as H17,
       sum(case when date_part('hour',tf0.last_update_time) =18 then 1 else 0 end) as H18,
       sum(case when date_part('hour',tf0.last_update_time) =19 then 1 else 0 end) as H19,
       sum(case when date_part('hour',tf0.last_update_time) =20 then 1 else 0 end) as H20,
       sum(case when date_part('hour',tf0.last_update_time) =21 then 1 else 0 end) as H21,
       sum(case when date_part('hour',tf0.last_update_time) =22 then 1 else 0 end) as H22,
       sum(case when date_part('hour',tf0.last_update_time) =23 then 1 else 0 end) as H23
from tmp_file tf0
 where tf0.file not in ('archive_status')
group by to_char(date_trunc('day',tf0.last_update_time),'yyyymmdd')
order by to_char(date_trunc('day',tf0.last_update_time),'yyyymmdd') desc
;  

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#WAI">Back to Wal / Archive Information</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>


-- -------------------------------------------------------------------------
--                                 Archive settings
-- -------------------------------------------------------------------------
\qecho <h3 id="4AS"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Archive Settings</b></font></h3>
\echo 'Query Achive settings ...'
select name,setting from sys_settings where name like 'archive%';

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#WAI">Back to Wal / Archive Information</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                 Archiver process status
-- -------------------------------------------------------------------------
\qecho <h3 id="4APS"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Archiver Process Status</b></font></h3>
\echo 'Query Archiver process status ...'
select sys_walfile_name(sys_current_wal_lsn()) now_wal, * from sys_stat_archiver;

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#WAI">Back to Wal / Archive Information</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                 Archiver status
-- -------------------------------------------------------------------------
\qecho <h3 id="4ASS"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Archiver Status</b></font></h3>
\echo 'Query archiver status ...'
select pg_walfile_name(pg_current_wal_lsn()),last_archived_wal,last_failed_wal,
('x'||substring(pg_walfile_name(pg_current_wal_lsn()),9,8))::bit(32)::int*256 +
('x'||substring(pg_walfile_name(pg_current_wal_lsn()),17))::bit(32)::int -
('x'||substring(last_archived_wal,9,8))::bit(32)::int*256 -
('x'||substring(last_archived_wal,17))::bit(32)::int
as diff from sys_stat_archiver;

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#WAI">Back to Wal / Archive Information</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- ==============================================================================
--                                5. Users / Roles / Schema Details
-- ==============================================================================
\qecho <h3 id="URSD"><font size="+2" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Users / Roles / Schemas Details</b></font></h3>
\qecho <ul>
\qecho <li><a href="#5UD">Users Details</a></li>
\qecho <li><a href="#5RD">Roles Details</a></li>
\qecho <li><a href="#5SD">Schema Details</a></li>
\qecho <li><a href="#5USC">Users Search_path Config</a></li>
\qecho </ul>
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                Users details
-- -------------------------------------------------------------------------
\qecho <h3 id="5UD"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Users Details</b></font></h3>
\echo 'Query Users details ...'
select usename,usesuper,valuntil from pg_user;
--select usename,usesuper,valuntil from pg_shadow;

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#URSD">Back to Users / Roles / Schema Details</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                Roles details
-- -------------------------------------------------------------------------
\qecho <h3 id="5RD"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Roles Details</b></font></h3>
\echo 'Query Roles details ...'
SELECT oid,rolname,rolsuper,rolreplication,rolconnlimit,rolconfig from pg_roles WHERE rolcanlogin;

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#URSD">Back to Users / Roles / Schema Details</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                Schema details
-- -------------------------------------------------------------------------
\qecho <h3 id="5SD"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Schema Details</b></font></h3>
\echo 'Query Schema details ...'
--select nspname as schema_name , pg_get_userbyid(nspowner) as schema_owner from pg_catalog.pg_namespace;
select schema_name,schema_owner from information_schema.schemata;

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#URSD">Back to Users / Roles / Schema Details</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                Search_path of users
-- -------------------------------------------------------------------------
\qecho <h3 id="5USC"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Users Search_path Config</b></font></h3>
\echo 'Query Users Search_path Config ...'
SELECT r.rolname, d.datname, drs.setconfig
FROM pg_db_role_setting drs
LEFT JOIN pg_roles r ON r.oid = drs.setrole
LEFT JOIN pg_database d ON d.oid = drs.setdatabase;

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#URSD">Back to Users / Roles / Schema Details</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- ==============================================================================
--                                6. Security Information
-- ==============================================================================
\qecho <h3 id="SI"><font size="+2" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Security Information</b></font></h3>
\qecho <ul>
\qecho <li><a href="#6SR">sys_hba rules</a></li>
\qecho <li><a href="#6CUR">Common user rules</a></li>
\qecho <li><a href="#6CUF">Common user-defined function</a></li>
\qecho <li><a href="#6UTH">Unlogged table and hash indexes</a></li>
\qecho </ul>
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                sys_hba file rules
-- -------------------------------------------------------------------------
\qecho <h3 id="6SR"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>sys_hba rules</b></font></h3>
\echo 'Query sys_hba rules ...'
select * from pg_hba_file_rules;

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#SI">Back to Security Information</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>


-- -------------------------------------------------------------------------
--                                Rule security check on common user objects
-- -------------------------------------------------------------------------
\qecho <h3 id="6CUR"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Common user rules</b></font></h3>
\echo 'Query Common user rules ...'
select current_database(),a.schemaname,a.tablename,a.rulename,a.definition from pg_rules a,pg_namespace b,pg_class c,pg_authid d where a.schemaname=b.nspname and a.tablename=c.relname and d.oid=c.relowner and not d.rolsuper union all select current_database(),a.schemaname,a.viewname,a.viewowner,a.definition from pg_views a,pg_namespace b,pg_class c,pg_authid d where a.schemaname=b.nspname and a.viewname=c.relname and d.oid=c.relowner and not d.rolsuper;

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#SI">Back to Security Information</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                Common user-defined function security check
-- -------------------------------------------------------------------------
\qecho <h3 id="6CUF"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Common user-defined function</b></font></h3>
\echo 'Query Common user-defined function security check ...'
select current_database(),b.rolname,c.nspname,a.proname from pg_proc a,pg_authid b,pg_namespace c where a.proowner=b.oid and a.pronamespace=c.oid and not b.rolsuper and not a.prosecdef;

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#SI">Back to Security Information</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                Unlogged table and hash indexes
-- -------------------------------------------------------------------------
\qecho <h3 id="6UTH"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Unlogged table and hash indexes</b></font></h3>
\echo 'Query Unlogged table and hash indexes ...'
\qecho <div style="overflow-x: auto; overflow-y: auto; min-height: 50px; max-height: 500px; width:%100px;">
--Unlogged tables
\qecho <b>Display unlogged tables</b>
select current_database(),t3.rolname,t2.nspname,t1.relname from pg_class t1,pg_namespace t2,pg_authid t3 where t1.relnamespace=t2.oid and t1.relowner=t3.oid and t1.relpersistence=$$u$$;
\qecho <hr align="left" size="1" color="Gray" width="20%" />
--Hash indexes
\qecho <b>Display Hash indexes</b>
select current_database(),pg_get_indexdef(oid) from pg_class where relkind=$$i$$ and pg_get_indexdef(oid) ~ $$USING hash$$;
\qecho </div>

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#SI">Back to Security Information</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- ==============================================================================
--                               7. Objects Statistics
-- ==============================================================================
\qecho <h3 id="OS"><font size="+2" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Objects Statistics</b></font></h3>
\qecho <ul>
\qecho <li><a href="#7OC">Objects Count</a></li>
\qecho <li><a href="#7TS">Tables Size</a></li>
\qecho <li><a href="#7AO">All Objects</a></li>
\qecho <li><a href="#7PT">Partitioned Tables</a></li>
\qecho <li><a href="#7VD">Vaccum/Analyze Details</a></li>
\qecho <li><a href="#7MI">Missing Indexes</a></li>
\qecho <li><a href="#7FKC">Foreign Key Constraint</a></li>
\qecho <li><a href="#7FSD">Foreign Server Details</a></li>
\qecho <li><a href="#7FT">Foreign Tables</a></li>
\qecho <li><a href="#7SS">Sequences Summary</a></li>
\qecho <li><a href="#7TSS">Trigger Summary</a></li>
\qecho <li><a href="#7UDS">Used Datatype Statistics</a></li>
\qecho <li><a href="#7UOS">Users Objects Summary</a></li>
\qecho </ul>
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                Objects Count
-- -------------------------------------------------------------------------
\qecho <h3 id="7OC"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Objects Count</b></font></h3>
\echo 'Query Objects count for each Database Schema ...'
select 
    nsp.nspname as SchemaName
    ,case cls.relkind
        when 'r' then 'TABLE'
        when 'm' then 'MATERIALIZED_VIEW'
        when 'i' then 'INDEX'
        when 'S' then 'SEQUENCE'
        when 'v' then 'VIEW'
        when 'c' then 'composite type'
        when 't' then 'TOAST'
        when 'f' then 'foreign table'
        when 'p' then 'partitioned_table'
        when 'I' then 'partitioned_index'
        else cls.relkind::text
    end as ObjectType,
    COUNT(*) cnt
from sys_class cls
join sys_namespace nsp 
 on nsp.oid = cls.relnamespace
where nsp.nspname not in ('pg_catalog','sys_catalog','information_schema','sys','sysaudit','sysmac','src_restrict')
  and nsp.nspname not like 'sys_toast%'
GROUP BY nsp.nspname,cls.relkind
UNION all
SELECT n.nspname as "Schema",
 CASE p.prokind
  WHEN 'a' THEN 'agg'
  WHEN 'w' THEN 'window'
  WHEN 'p' THEN 'proc'
  ELSE 'func'
 END as "Type",
 COUNT(*) cnt
FROM sys_proc p
LEFT JOIN sys_namespace n ON n.oid = p.pronamespace
WHERE sys_function_is_visible(p.oid)
AND n.nspname not in ('pg_catalog','sys_catalog','information_schema','sys','sysaudit','sysmac','src_restrict')
GROUP BY n.nspname ,p.prokind
order by SchemaName;
\qecho <hr align="left" size="1" color="Gray" width="20%" />
--INVALID Objects
\qecho <b>Display INVALID Objects</b>
select * from dba_objects where status='INVALID';


\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#OS">Back to Objects Statistics</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                Tables size
-- -------------------------------------------------------------------------
\qecho <h3 id="7TS"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Tables size</b></font></h3>
\echo 'Query Tables size ...'
\qecho <div style="overflow-x: auto; overflow-y: auto; min-height: 50px; max-height: 500px; width:%100px;">
--select schemaname as schema_owner,
--relname as table_name,
--pg_size_pretty(pg_total_relation_size(relid)) as total_size,
--pg_size_pretty(pg_relation_size(relid)) as used_size,
--pg_size_pretty(pg_total_relation_size(relid) - pg_relation_size(relid))
--as free_space
--from pg_catalog.pg_statio_user_tables
--order by pg_total_relation_size(relid) desc,
--pg_relation_size(relid) desc;
SELECT
	t.table_catalog as db,
	n.nspname AS schemaname,
	c.relname,
	c.reltuples::numeric as rowcount,
	sys_size_pretty(sys_table_size ( '"' || nspname || '"."' || relname || '"' )) AS table_size,
  sys_size_pretty(sys_indexes_size ( '"' || nspname || '"."' || relname || '"' )) AS indexes_size,
	sys_size_pretty (sys_total_relation_size ( '"' || nspname || '"."' || relname || '"' )) AS total_size --,sys_relation_filepath(t."table_name") filepath
FROM sys_class C 
	LEFT JOIN sys_namespace N ON ( N.oid = C.relnamespace ) 
	left join information_schema.tables t on (n.nspname= t.table_schema and c.relname=t."table_name" )
WHERE
	nspname NOT IN ( 'pg_catalog', 'information_schema' ) 
	AND relkind in ('r','p')  
ORDER BY
	reltuples DESC 
	LIMIT 20
;

\qecho </div>
\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#OS">Back to Objects Statistics</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                List All Objects of current database
-- -------------------------------------------------------------------------
\qecho <h3 id="7AO"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>All Objects</b></font></h3>
\echo 'Query All Objects ...'
\qecho <div style="overflow-x: auto; overflow-y: auto; min-height: 50px; max-height: 500px; width:%100px;">
SELECT
	oid::regclass,
	relnamespace::regnamespace,
	relpages::bigint blks,
	pg_stat_get_live_tuples(oid) AS n_live_tup,
	pg_stat_get_dead_tuples(oid) AS n_dead_tup,
	pg_stat_get_tuples_inserted(oid) n_tup_ins,
	pg_stat_get_tuples_updated(oid) n_tup_upd,
	pg_stat_get_tuples_deleted(oid) n_tup_del,
	pg_stat_get_tuples_hot_updated(oid) n_tup_hot_upd,
	pg_relation_size(oid) rel_size,
	pg_table_size(oid) tot_tab_size,
	pg_total_relation_size(oid) tab_ind_size,
	age(relfrozenxid) rel_age,
	GREATEST(pg_stat_get_last_autovacuum_time(oid),
	pg_stat_get_last_vacuum_time(oid)) vaccum_time,
	GREATEST(pg_stat_get_last_autoanalyze_time(oid),
	pg_stat_get_last_analyze_time(oid)) analyze_time,
	pg_stat_get_vacuum_count(oid)+ pg_stat_get_autovacuum_count(oid) vaccum_count
FROM
	pg_class
WHERE
	relkind IN ('r', 't', 'p', 'm', '');

\qecho </div>

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#OS">Back to Objects Statistics</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                List all partitioned tables
-- -------------------------------------------------------------------------
\qecho <h3 id="7PT"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Partitioned Tables</b></font></h3>
\echo 'Query Partitioned tables ...'
SELECT
nmsp_parent.nspname AS parent_schema,
parent.relname AS parent,
nmsp_child.nspname AS child_schema,
child.relname AS child
FROM pg_inherits
JOIN pg_class parent ON pg_inherits.inhparent = parent.oid
JOIN pg_class child ON pg_inherits.inhrelid = child.oid
JOIN pg_namespace nmsp_parent ON nmsp_parent.oid = parent.relnamespace
JOIN pg_namespace nmsp_child ON nmsp_child.oid = child.relnamespace;

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#OS">Back to Objects Statistics</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                Vaccum/Analyze details
-- -------------------------------------------------------------------------
\qecho <h3 id="7VD"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Vaccum/analyze details</b></font></h3>
\echo 'Query Vaccum/analyze details ...'
\qecho <div style="overflow-x: auto; overflow-y: auto; min-height: 50px; max-height: 500px; width:%100px;">
select * from pg_stat_user_tables;

\qecho </div>
\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#OS">Back to Objects Statistics</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                Finding a Missing Indexes of the schema
-- -------------------------------------------------------------------------
\qecho <h3 id="7MI"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Missing Indexes</b></font></h3>
\echo 'Query Missing indexes ...'
SELECT 
 relname AS TableName
 ,seq_scan-idx_scan AS TotalSeqScan
 ,CASE WHEN seq_scan-idx_scan > 0 
  THEN 'Missing Index Found' 
  ELSE 'Missing Index Not Found' 
 END AS MissingIndex
 ,pg_size_pretty(pg_relation_size(relname::regclass)) AS TableSize
 ,idx_scan AS TotalIndexScan
FROM pg_stat_all_tables
WHERE schemaname='public'
 AND pg_relation_size(relname::regclass)>100000 
ORDER BY 2 DESC;

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#OS">Back to Objects Statistics</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                 All Foreign Key Constraint
-- -------------------------------------------------------------------------
\qecho <h3 id="7FKC"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Foreign Key Constraint</b></font></h3>
\echo 'Query All Foreign Key Constraint ...'
SELECT
 tc.constraint_name AS ForeignKeyConstraintName
 ,tc.table_name AS TableName
 ,kcu.column_name AS ColumnName
 ,ccu.table_name AS ForeignKeyTableName
 ,ccu.column_name AS ForeignKeyColumn
FROM information_schema.table_constraints AS tc 
JOIN information_schema.key_column_usage AS kcu
 ON tc.constraint_name = kcu.constraint_name
JOIN information_schema.constraint_column_usage AS ccu
 ON ccu.constraint_name = tc.constraint_name
WHERE tc.constraint_type = 'FOREIGN KEY'; 
\qecho <hr align="left" size="1" color="Gray" width="20%" />

--Display constraints
\qecho <b>Display constraints</b>
SELECT
o.conname AS constraint_name,
(SELECT nspname FROM pg_namespace WHERE oid=m.relnamespace) AS source_schema,
m.relname AS source_table,
(SELECT a.attname FROM pg_attribute a WHERE a.attrelid = m.oid AND a.attnum = o.conkey[1] AND a.attisdropped = false) AS source_column,
(SELECT nspname FROM pg_namespace WHERE oid=f.relnamespace) AS target_schema,
f.relname AS target_table,
(SELECT a.attname FROM pg_attribute a WHERE a.attrelid = f.oid AND a.attnum = o.confkey[1] AND a.attisdropped = false) AS target_column
FROM
pg_constraint o LEFT JOIN pg_class f ON f.oid = o.confrelid LEFT JOIN pg_class m ON m.oid = o.conrelid
WHERE
o.contype = 'f' AND o.conrelid IN (SELECT oid FROM pg_class c WHERE c.relkind = 'r');

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#OS">Back to Objects Statistics</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>


-- -------------------------------------------------------------------------
--                                Foreign server details
-- -------------------------------------------------------------------------
\qecho <h3 id="7FSD"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Foreign Server Details</b></font></h3>
\echo 'Query Foreign server details ...'
select srvname,srvowner,srvoptions,fdwname,srvversion,srvtype from pg_foreign_server join pg_foreign_data_wrapper b on b.oid=srvfdw;

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#OS">Back to Objects Statistics</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                Foreign tables
-- -------------------------------------------------------------------------
\qecho <h3 id="7FT"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Foreign Tables Details</b></font></h3>
\echo 'Query Foreign tables details ...'
SELECT n.nspname AS "Schema",
c.relname AS "Table",
s.srvname AS "Server",
CASE WHEN ftoptions IS NULL THEN '' ELSE '(' || pg_catalog.array_to_string(ARRAY(SELECT pg_catalog.quote_ident(option_name) || ' ' || pg_catalog.quote_literal(option_value) FROM pg_catalog.pg_options_to_table(ftoptions)), ', ') || ')' END AS "FDW options",
d.description AS "Description"
FROM pg_catalog.pg_foreign_table ft
INNER JOIN pg_catalog.pg_class c ON c.oid = ft.ftrelid
INNER JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
INNER JOIN pg_catalog.pg_foreign_server s ON s.oid = ft.ftserver
LEFT JOIN pg_catalog.pg_description d
ON d.classoid = c.tableoid AND d.objoid = c.oid AND d.objsubid = 0
WHERE pg_catalog.pg_table_is_visible(c.oid)
ORDER BY 1, 2;

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#OS">Back to Objects Statistics</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                Sequences Summary
-- -------------------------------------------------------------------------
\qecho <h3 id="7SS"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Sequences Summary</b></font></h3>
\echo 'Query Sequences summary ...'
select * from pg_sequences;

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#OS">Back to Objects Statistics</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                Trigger Summary
-- -------------------------------------------------------------------------
\qecho <h3 id="7TSS"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Trigger Summary</b></font></h3>
\echo 'Query Trigger Summary ...'
select current_database(),relname,tgname,proname,tgenabled from pg_trigger t1,pg_class t2,pg_proc t3 where t1.tgfoid=t3.oid and t1.tgrelid=t2.oid;
\qecho <hr align="left" size="1" color="Gray" width="20%" />

select current_database(),rolname,proname,evtname,evtevent,evtenabled,evttags from pg_event_trigger t1,pg_proc t2,pg_authid t3 where t1.evtfoid=t2.oid and t1.evtowner=t3.oid;

\qecho <hr align="left" size="1" color="Gray" width="20%" />

-- To list all the triggers
\qecho <b>Display all triggers</b>
SELECT
  ns.nspname||'.'||tbl.relname AS trigger_table,
  trg.tgname AS "trigger_name",
    CASE trg.tgtype::INTEGER & 66
        WHEN 2 THEN 'BEFORE'
        WHEN 64 THEN 'INSTEAD OF'
        ELSE 'AFTER'
    END AS "action_timing",
   CASE trg.tgtype::INTEGER & cast(28 AS int2)
     WHEN 16 THEN 'UPDATE'
     WHEN 8 THEN 'DELETE'
     WHEN 4 THEN 'INSERT'
     WHEN 20 THEN 'INSERT, UPDATE'
     WHEN 28 THEN 'INSERT, UPDATE, DELETE'
     WHEN 24 THEN 'UPDATE, DELETE'
     WHEN 12 THEN 'INSERT, DELETE'
   END AS trigger_event,
   obj_description(trg.oid) AS remarks,
     CASE
      WHEN trg.tgenabled='O' THEN 'ENABLED'
        ELSE 'DISABLED'
    END AS status,
    CASE trg.tgtype::INTEGER & 1
      WHEN 1 THEN 'ROW'::TEXT
      ELSE 'STATEMENT'::TEXT
    END AS trigger_level
FROM 
  pg_trigger trg
 JOIN pg_class tbl ON trg.tgrelid = tbl.oid
 JOIN pg_namespace ns ON ns.oid = tbl.relnamespace
WHERE 
  trg.tgname not LIKE 'RI_ConstraintTrigger%'
  AND trg.tgname not LIKE 'pg_sync_pg%';

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#OS">Back to Objects Statistics</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                 Used Datatype Statistics
-- -------------------------------------------------------------------------
\qecho <h3 id="7UDS"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Used Datatype Statistics</b></font></h3>
\echo 'Query Used Datatype Statistics ...'
\qecho <div style="overflow-x: auto; overflow-y: auto; min-height: 50px; max-height: 500px; width:%100px;">
select current_database(),b.typname,count(*) from sys_attribute a,sys_type b where a.atttypid=b.oid and a.attrelid in (select oid from sys_class where relnamespace not in (select oid from sys_namespace where nspname ~ $$^pg_$$ or nspname=$$information_schema$$)) group by 1,2 order by 3 desc;
\qecho </div>

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#OS">Back to Objects Statistics</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                  Users Objects Summary
-- -------------------------------------------------------------------------
\qecho <h3 id="7UOS"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Users Objects</b></font></h3>
\echo 'Query Users Objects summary ...'
select current_database(),rolname,nspname,relkind,count(*) from pg_class a,pg_authid b,pg_namespace c where a.relnamespace=c.oid and a.relowner=b.oid and nspname !~ $$^pg_$$ and nspname !~ $$^sys_$$ and nspname<>$$information_schema$$ group by 1,2,3,4 order by 5 desc;

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#OS">Back to Objects Statistics</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- ==============================================================================
--                               8. Streaming Replications
-- ==============================================================================
\qecho <h3 id="SR"><font size="+2" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Streaming Replications</b></font></h3>
\qecho <ul>
\qecho <li><a href="#8RD">Replication Details</a></li>
\qecho <li><a href="#8RLD">Replication Lag Details</a></li>
\qecho <li><a href="#8RSD">Replication Slot Details</a></li>
\qecho <li><a href="#8LRD">Logical Replication Details</a></li>
\qecho </ul>
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                Replication details
-- -------------------------------------------------------------------------
\qecho <h3 id="8RD"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Replication Details</b></font></h3>
\echo 'Query Replication details ...'
\qecho <b> Display Primary database </b>
--Primary database
select * from pg_stat_replication;
\qecho <hr align="left" size="1" color="Gray" width="20%" />

--Standby database
\qecho <b> Display Standby database </b>
select * from pg_stat_wal_receiver;
\qecho <hr align="left" size="1" color="Gray" width="20%" />

--select pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn(), pg_last_xact_replay_timestamp();

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#SR">Back to Streaming Replications</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                Replication lag details
-- -------------------------------------------------------------------------
\qecho <h3 id="8RLD"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Replication Lag Details</b></font></h3>
\echo 'Query Replication lag details ...'

-- Find lag in bytes( run on standby)
\qecho <b> Display Replication Lag (in GB) </b>
SELECT round(pg_wal_lsn_diff(sent_lsn, replay_lsn)/1024/1024/1024,2) as GB_lag from pg_stat_replication;

\qecho <hr align="left" size="1" color="Gray" width="20%" />

-- Find lag in seconds( run on standby)
\qecho <b> Display Replication Lag (in seconds)</b>
SELECT
	CASE
		WHEN pg_last_wal_receive_lsn() =
pg_last_wal_replay_lsn()
THEN 0
		ELSE
EXTRACT (EPOCH
	FROM
		now() - pg_last_xact_replay_timestamp())
	END AS lag_seconds;

-- Find database stream conflicts
\qecho <b> Display Replication conflicts </b>
select * from sys_stat_database_conflicts;

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#SR">Back to Streaming Replications</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                Replication slot details
-- -------------------------------------------------------------------------
\qecho <h3 id="8RSD"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Replication Slot Details</b></font></h3>
\echo 'Query Replication slot details ...'
SELECT
	redo_lsn,
	slot_name,
	restart_lsn,
	active,
	round((redo_lsn-restart_lsn) / 1024 / 1024 / 1024,
	2) AS GB_lag
FROM
	pg_control_checkpoint(),
	pg_replication_slots;

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#SR">Back to Streaming Replications</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                Logical Replication Details
-- -------------------------------------------------------------------------
\qecho <h3 id="8LRD"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Logical Replication Details</b></font></h3>
\echo 'Query Logical replication details ...'
-- Find database stream conflicts
\qecho <b> Display Publication </b>
select * from sys_publication;

\qecho <b> Display Publication tables</b>
select * from sys_publication_tables;

\qecho <b> Display subscription </b>
select * from sys_stat_replication;

\qecho <b> Display replication rate </b>
select * from sys_stat_subscription;

\qecho <b> Display Subscription</b>
select * from sys_subscription;

\qecho <b> Display subscription tables</b>
select *,srrelid::regclass from sys_subscription_rel; 

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#SR">Back to Streaming Replications</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>


-- ==============================================================================
--                               9. Performance Statistics
-- ==============================================================================
\qecho <h3 id="PS"><font size="+2" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Performance Statistics</b></font></h3>
\qecho <ul>
\qecho <li><a href="#9DS">Database Statistics</a></li>
\qecho <li><a href="#9BI">Bgwriter Info</a></li>
\qecho <li><a href="#9TUI">Tables Usage Info</a></li>
\qecho <li><a href="#9IUI">Indexes Usage Info</a></li>
\qecho <li><a href="#9NSI">Number and size of indexes</a></li>
\qecho <li><a href="#9ULI">Unused or less used indexes</a></li>
\qecho <li><a href="#9PK">Primary Keys</a></li>
\qecho </ul>
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                Database statistics
-- -------------------------------------------------------------------------
\qecho <h3 id="9DS"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Database Statistics</b></font></h3>
\echo 'Query Database statistics ...'
select datname,round(100*(xact_rollback::numeric/(case when xact_commit > 0 then xact_commit else 1 end + xact_rollback)),2)||$$ %$$ rollback_ratio, round(100*(blks_hit::numeric/(case when blks_read>0 then blks_read else 1 end + blks_hit)),2)||$$ %$$ hit_ratio, blk_read_time, blk_write_time, conflicts, deadlocks from sys_stat_database;

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#PS">Back to Performance Statistics</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                Bgwriter info
-- -------------------------------------------------------------------------
\qecho <h3 id="9BI"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Bgwriter Info</b></font></h3>
\echo 'Query Bgwriter info ...'
SELECT * FROM pg_stat_bgwriter ;

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#PS">Back to Performance Statistics</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                Table usage Information
-- -------------------------------------------------------------------------
\qecho <h3 id="9TUI"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Tables usage Information</b></font></h3>
\echo 'Query Table usage Information  ...'
\qecho <div style="overflow-x: auto; overflow-y: auto; min-height: 50px; max-height: 500px; width:%100px;">
select oid,relnamespace, relpages::bigint blks,pg_stat_get_live_tuples(oid) AS n_live_tup,pg_stat_get_dead_tuples(oid) AS n_dead_tup,
   pg_stat_get_tuples_inserted(oid) n_tup_ins, pg_stat_get_tuples_updated(oid) n_tup_upd, pg_stat_get_tuples_deleted(oid) n_tup_del, pg_stat_get_tuples_hot_updated(oid) n_tup_hot_upd,
   pg_relation_size(oid) rel_size,  pg_table_size(oid) tot_tab_size, pg_total_relation_size(oid) tab_ind_size, age(relfrozenxid) rel_age,
   GREATEST(pg_stat_get_last_autovacuum_time(oid),pg_stat_get_last_vacuum_time(oid)) as vaccum_time, GREATEST(pg_stat_get_last_autoanalyze_time(oid),pg_stat_get_last_analyze_time(oid)) as analyze_time,
 pg_stat_get_vacuum_count(oid)+pg_stat_get_autovacuum_count(oid) as vaccum_count
 FROM pg_class WHERE relkind in ('r','t','p','m','');
\qecho </div>

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#PS">Back to Performance Statistics</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                Index Usage Information
-- -------------------------------------------------------------------------
\qecho <h3 id="9IUI"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Indexes usage Information</b></font></h3>
\echo 'Query Indexes usage Information  ...'
\qecho <div style="overflow-x: auto; overflow-y: auto; min-height: 50px; max-height: 500px; width:%100px;">
SELECT indexrelid,indrelid,indisunique,indisprimary, pg_stat_get_numscans(indexrelid),pg_table_size(indexrelid) from pg_index;
\qecho </div>

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#PS">Back to Performance Statistics</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                Number and size of indexes
-- -------------------------------------------------------------------------
\qecho <h3 id="9NSI"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Number and size of indexes</b></font></h3>
\echo 'Query Number and size of indexes  ...'
select current_database(), t2.nspname, t1.relname, sys_size_pretty(sys_relation_size(t1.oid)), t3.idx_cnt from pg_class t1, pg_namespace t2, (select indrelid,count(*) idx_cnt from pg_index group by 1 having count(*)>4) t3 where t1.oid=t3.indrelid and t1.relnamespace=t2.oid and sys_relation_size(t1.oid)/1024/1024.0>10 order by t3.idx_cnt desc;

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#PS">Back to Performance Statistics</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                Unused or less used indexes
-- -------------------------------------------------------------------------
\qecho <h3 id="9ULI"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Unused or less used indexes</b></font></h3>
\echo 'Query Unused or less used indexes  ...'
select current_database(),t2.schemaname,t2.relname,t2.indexrelname,t2.idx_scan,t2.idx_tup_read,t2.idx_tup_fetch,sys_size_pretty(sys_relation_size(indexrelid)) from sys_stat_all_tables t1,sys_stat_all_indexes t2 where t1.relid=t2.relid and t2.idx_scan<10 and t2.schemaname not in ($$pg_toast$$,$$pg_catalog$$) and indexrelid not in (select conindid from sys_constraint where contype in ($$p$$,$$u$$,$$f$$)) and sys_relation_size(indexrelid)>65536 order by sys_relation_size(indexrelid) desc;

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#PS">Back to Performance Statistics</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                Finding table of primary keys
-- -------------------------------------------------------------------------
\qecho <h3 id="9PK"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Primary keys</b></font></h3>
\echo 'Query Primary keys ...'
-- To list all the tables of your database with their primary keys
SELECT 
  tc.table_schema,
  tc.table_name,
  kc.column_name
FROM
  information_schema.table_constraints tc,
  information_schema.key_column_usage kc
WHERE
  tc.constraint_type = 'PRIMARY KEY'
  AND kc.table_name = tc.table_name 
  AND kc.table_schema = tc.table_schema
  AND kc.constraint_name = tc.constraint_name
ORDER BY 1, 2;

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#PS">Back to Performance Statistics</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>


-- ==============================================================================
--                                10. Locks Information
-- ==============================================================================
\qecho <h3 id="LI"><font size="+2" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Locks Information</b></font></h3>
\qecho <ul>
\qecho <li><a href="#10LWC">Lock Wait and Chain info</a></li>
\qecho <li><a href="#10IC">Inheritance Check</a></li>
\qecho </ul>
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                 Lock Wait and Chain info
-- -------------------------------------------------------------------------
\qecho <h3 id="10LWC"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Lock Wait and Chain info</b></font></h3>
\echo 'Query Lock Wait and Chain info ...'
SELECT
	t.relname,
	l.locktype,
	page,
	virtualtransaction,
	pid,
	mode,
	GRANTED
FROM
	pg_locks l,
	pg_stat_all_tables t
WHERE
	l.relation = t.relid
ORDER BY
	relation ASC;
\qecho <hr align="left" size="1" color="Gray" width="20%" />

--Lock chain info
\qecho <b>Display Lock chain info</b>
SELECT pid,pg_blocking_pids(pid) FROM pg_stat_get_activity(NULL) WHERE wait_event_type = 'Lock';

\qecho <hr align="left" size="1" color="Gray" width="20%" />
--Lock wait info
\qecho <b>Display Lock wait info</b>
with    
t_wait as    
(    
  select a.mode,a.locktype,a.database,a.relation,a.page,a.tuple,a.classid,a.granted,   
  a.objid,a.objsubid,a.pid,a.virtualtransaction,a.virtualxid,a.transactionid,a.fastpath,    
  b.state,b.query,b.xact_start,b.query_start,b.usename,b.datname,b.client_addr,b.client_port,b.application_name   
    from pg_locks a,sys_stat_activity b where a.pid=b.pid and not a.granted   
),   
t_run as   
(   
  select a.mode,a.locktype,a.database,a.relation,a.page,a.tuple,a.classid,a.granted,   
  a.objid,a.objsubid,a.pid,a.virtualtransaction,a.virtualxid,a.transactionid,a.fastpath,   
  b.state,b.query,b.xact_start,b.query_start,b.usename,b.datname,b.client_addr,b.client_port,b.application_name   
    from pg_locks a,sys_stat_activity b where a.pid=b.pid and a.granted   
),   
t_overlap as   
(   
  select r.* from t_wait w join t_run r on   
  (   
    r.locktype is not distinct from w.locktype and   
    r.database is not distinct from w.database and   
    r.relation is not distinct from w.relation and   
    r.page is not distinct from w.page and   
    r.tuple is not distinct from w.tuple and   
    r.virtualxid is not distinct from w.virtualxid and   
    r.transactionid is not distinct from w.transactionid and   
    r.classid is not distinct from w.classid and   
    r.objid is not distinct from w.objid and   
    r.objsubid is not distinct from w.objsubid and   
    r.pid <> w.pid   
  )    
),    
t_unionall as    
(    
  select r.* from t_overlap r    
  union all    
  select w.* from t_wait w    
)    
select locktype,datname,relation::regclass,page,tuple,virtualxid,transactionid::text,classid::regclass,objid,objsubid,   
string_agg(   
'Pid: '||case when pid is null then 'NULL' else pid::text end||chr(10)||   
'Lock_Granted: '||case when granted is null then 'NULL' else granted::text end||' , Mode: '||case when mode is null then 'NULL' else mode::text end||' , FastPath: '||case when fastpath is null then 'NULL' else fastpath::text end||' , VirtualTransaction: '||case when virtualtransaction is null then 'NULL' else virtualtransaction::text end||' , Session_State: '||case when state is null then 'NULL' else state::text end||chr(10)||   
'Username: '||case when usename is null then 'NULL' else usename::text end||' , Database: '||case when datname is null then 'NULL' else datname::text end||' , Client_Addr: '||case when client_addr is null then 'NULL' else client_addr::text end||' , Client_Port: '||case when client_port is null then 'NULL' else client_port::text end||' , Application_Name: '||case when application_name is null then 'NULL' else application_name::text end||chr(10)||    
'Xact_Start: '||case when xact_start is null then 'NULL' else xact_start::text end||' , Query_Start: '||case when query_start is null then 'NULL' else query_start::text end||' , Xact_Elapse: '||case when (now()-xact_start) is null then 'NULL' else (now()-xact_start)::text end||' , Query_Elapse: '||case when (now()-query_start) is null then 'NULL' else (now()-query_start)::text end||chr(10)||    
'SQL (Current SQL in Transaction): '||chr(10)||  
case when query is null then 'NULL' else query::text end,    
chr(10)||'--------'||chr(10)    
order by    
  (  case mode    
    when 'INVALID' then 0   
    when 'AccessShareLock' then 1   
    when 'RowShareLock' then 2   
    when 'RowExclusiveLock' then 3   
    when 'ShareUpdateExclusiveLock' then 4   
    when 'ShareLock' then 5   
    when 'ShareRowExclusiveLock' then 6   
    when 'ExclusiveLock' then 7   
    when 'AccessExclusiveLock' then 8   
    else 0   
  end  ) desc,   
  (case when granted then 0 else 1 end)  
) as lock_conflict  
from t_unionall   
group by   
locktype,datname,relation,page,tuple,virtualxid,transactionid::text,classid,objid,objsubid ;

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#LI">Back to Locks Information</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                 Inheritance Check
-- -------------------------------------------------------------------------
\qecho <h3 id="10IC"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Inheritance Check</b></font></h3>
\echo 'Query Inheritance Check ...'
select inhrelid::regclass,inhparent::regclass,inhseqno from pg_inherits order by 2,3;

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#LI">Back to Locks Information</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- ==============================================================================
--                               11. Extensions Details
-- ==============================================================================
\qecho <h3 id="ED"><font size="+2" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Extensions Details</b></font></h3>
\qecho <ul>
\qecho <li><a href="#11IE">Installed extensions</a></li>
\qecho <li><a href="#11AE">Available extensions</a></li>
\qecho </ul>
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                List installed extensions
-- -------------------------------------------------------------------------
\qecho <h3 id="11IE"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Installed extensions</b></font></h3>
\echo 'Query installed extension ...'
SELECT current_database(),e.extname AS "Name", e.extversion AS "Version", n.nspname AS "Schema", c.description AS "Description"
FROM sys_extension e LEFT JOIN sys_namespace n ON n.oid = e.extnamespace LEFT JOIN sys_description c ON c.objoid = e.oid AND c.classoid = 'sys_extension'::regclass
ORDER BY 1;

\qecho <b> KES language support </b>
select * from sys_language;


\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#ED">Back to Extensions Details</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                List available extensions
-- -------------------------------------------------------------------------
\qecho <h3 id="11AE"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Available extensions</b></font></h3>
\echo 'Query available extension ...'
\qecho <div style="overflow-x: auto; overflow-y: auto; min-height: 50px; max-height: 500px; width:%100px;">
SELECT * FROM pg_available_extensions;
\qecho </div>

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#ED">Back to Extensions Details</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- ==============================================================================
--                               12. Vacuum Information
-- ==============================================================================
\qecho <h3 id="VI"><font size="+2" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Vacuum Information</b></font></h3>
\qecho <ul>
\qecho <li><a href="#12TEI">Table Inflation Check</a></li>
\qecho <li><a href="#12IIC">Index Inflation Check</a></li>
\qecho <li><a href="#12TA">Tables age</a></li>
\qecho <li><a href="#12VS">Vaccum Settings</a></li>
\qecho <li><a href="#12VO">Vacuum Operation</a></li>
\qecho <li><a href="#12LT">Long transaction or 2pc</a></li>
\qecho </ul>
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                 Table Inflation check
-- -------------------------------------------------------------------------
\qecho <h3 id="12TEI"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Table Inflation Check</b></font></h3>
\echo 'Query Table Inflation check ...'
SELECT
  current_database() AS db, schemaname, tablename, reltuples::bigint AS tups, relpages::bigint AS pages, otta,
  ROUND(CASE WHEN otta=0 OR sml.relpages=0 OR sml.relpages=otta THEN 0.0 ELSE sml.relpages/otta::numeric END,1) AS tbloat,
  CASE WHEN relpages < otta THEN 0 ELSE relpages::bigint - otta END AS wastedpages,
  CASE WHEN relpages < otta THEN 0 ELSE bs*(sml.relpages-otta)::bigint END AS wastedbytes,
  CASE WHEN relpages < otta THEN $$0 bytes$$::text ELSE (bs*(relpages-otta))::bigint || $$ bytes$$ END AS wastedsize,
  iname, ituples::bigint AS itups, ipages::bigint AS ipages, iotta,
  ROUND(CASE WHEN iotta=0 OR ipages=0 OR ipages=iotta THEN 0.0 ELSE ipages/iotta::numeric END,1) AS ibloat,
  CASE WHEN ipages < iotta THEN 0 ELSE ipages::bigint - iotta END AS wastedipages,
  CASE WHEN ipages < iotta THEN 0 ELSE bs*(ipages-iotta) END AS wastedibytes,
  CASE WHEN ipages < iotta THEN $$0 bytes$$ ELSE (bs*(ipages-iotta))::bigint || $$ bytes$$ END AS wastedisize,
  CASE WHEN relpages < otta THEN
    CASE WHEN ipages < iotta THEN 0 ELSE bs*(ipages-iotta::bigint) END
    ELSE CASE WHEN ipages < iotta THEN bs*(relpages-otta::bigint)
      ELSE bs*(relpages-otta::bigint + ipages-iotta::bigint) END
  END AS totalwastedbytes
FROM (
  SELECT
    nn.nspname AS schemaname,
    cc.relname AS tablename,
    COALESCE(cc.reltuples,0) AS reltuples,
    COALESCE(cc.relpages,0) AS relpages,
    COALESCE(bs,0) AS bs,
    COALESCE(CEIL((cc.reltuples*((datahdr+ma-
      (CASE WHEN datahdr%ma=0 THEN ma ELSE datahdr%ma END))+nullhdr2+4))/(bs-20::float)),0) AS otta,
    COALESCE(c2.relname,$$?$$) AS iname, COALESCE(c2.reltuples,0) AS ituples, COALESCE(c2.relpages,0) AS ipages,
    COALESCE(CEIL((c2.reltuples*(datahdr-12))/(bs-20::float)),0) AS iotta -- very rough approximation, assumes all cols
  FROM
     pg_class cc
  JOIN pg_namespace nn ON cc.relnamespace = nn.oid AND nn.nspname <> $$information_schema$$
  LEFT JOIN
  (
    SELECT
      ma,bs,foo.nspname,foo.relname,
      (datawidth+(hdr+ma-(case when hdr%ma=0 THEN ma ELSE hdr%ma END)))::numeric AS datahdr,
      (maxfracsum*(nullhdr+ma-(case when nullhdr%ma=0 THEN ma ELSE nullhdr%ma END))) AS nullhdr2
    FROM (
      SELECT
        ns.nspname, tbl.relname, hdr, ma, bs,
        SUM((1-coalesce(null_frac,0))*coalesce(avg_width, 2048)) AS datawidth,
        MAX(coalesce(null_frac,0)) AS maxfracsum,
        hdr+(
          SELECT 1+count(*)/8
          FROM pg_stats s2
          WHERE null_frac<>0 AND s2.schemaname = ns.nspname AND s2.tablename = tbl.relname
        )::numeric AS nullhdr
      FROM pg_attribute att 
      JOIN pg_class tbl ON att.attrelid = tbl.oid
      JOIN pg_namespace ns ON ns.oid = tbl.relnamespace 
      LEFT JOIN pg_stats s ON s.schemaname=ns.nspname
      AND s.tablename = tbl.relname
      AND s.inherited=false
      AND s.attname=att.attname,
      (
        SELECT
          (SELECT current_setting($$block_size$$)::numeric) AS bs,
            CASE WHEN SUBSTRING(SPLIT_PART(v, $$ $$, 2) FROM $$#"[0-9]+.[0-9]+#"%$$ for $$#$$)
              IN ($$8.0$$,$$8.1$$,$$8.2$$) THEN 27 ELSE 23 END AS hdr,
          CASE WHEN v ~ $$mingw32$$ OR v ~ $$64-bit$$ THEN 8 ELSE 4 END AS ma
        FROM (SELECT version() AS v) AS foo
      ) AS constants
      WHERE att.attnum > 0 AND tbl.relkind=$$r$$
      GROUP BY 1,2,3,4,5
    ) AS foo
  ) AS rs
  ON cc.relname = rs.relname AND nn.nspname = rs.nspname
  LEFT JOIN pg_index i ON indrelid = cc.oid
  LEFT JOIN pg_class c2 ON c2.oid = i.indexrelid
) AS sml order by wastedbytes desc limit 10;

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#VI">Back to Vacuum Information</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                 Index Inflation Info
-- -------------------------------------------------------------------------
\qecho <h3 id="12IIC"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Index Inflation Check</b></font></h3>
\echo 'Query Index inflation check ...'
SELECT
  current_database() AS db, schemaname, tablename, reltuples::bigint AS tups, relpages::bigint AS pages, otta,
  ROUND(CASE WHEN otta=0 OR sml.relpages=0 OR sml.relpages=otta THEN 0.0 ELSE sml.relpages/otta::numeric END,1) AS tbloat,
  CASE WHEN relpages < otta THEN 0 ELSE relpages::bigint - otta END AS wastedpages,
  CASE WHEN relpages < otta THEN 0 ELSE bs*(sml.relpages-otta)::bigint END AS wastedbytes,
  CASE WHEN relpages < otta THEN $$0 bytes$$::text ELSE (bs*(relpages-otta))::bigint || $$ bytes$$ END AS wastedsize,
  iname, ituples::bigint AS itups, ipages::bigint AS ipages, iotta,
  ROUND(CASE WHEN iotta=0 OR ipages=0 OR ipages=iotta THEN 0.0 ELSE ipages/iotta::numeric END,1) AS ibloat,
  CASE WHEN ipages < iotta THEN 0 ELSE ipages::bigint - iotta END AS wastedipages,
  CASE WHEN ipages < iotta THEN 0 ELSE bs*(ipages-iotta) END AS wastedibytes,
  CASE WHEN ipages < iotta THEN $$0 bytes$$ ELSE (bs*(ipages-iotta))::bigint || $$ bytes$$ END AS wastedisize,
  CASE WHEN relpages < otta THEN
    CASE WHEN ipages < iotta THEN 0 ELSE bs*(ipages-iotta::bigint) END
    ELSE CASE WHEN ipages < iotta THEN bs*(relpages-otta::bigint)
      ELSE bs*(relpages-otta::bigint + ipages-iotta::bigint) END
  END AS totalwastedbytes
FROM (
  SELECT
    nn.nspname AS schemaname,
    cc.relname AS tablename,
    COALESCE(cc.reltuples,0) AS reltuples,
    COALESCE(cc.relpages,0) AS relpages,
    COALESCE(bs,0) AS bs,
    COALESCE(CEIL((cc.reltuples*((datahdr+ma-
      (CASE WHEN datahdr%ma=0 THEN ma ELSE datahdr%ma END))+nullhdr2+4))/(bs-20::float)),0) AS otta,
    COALESCE(c2.relname,$$?$$) AS iname, COALESCE(c2.reltuples,0) AS ituples, COALESCE(c2.relpages,0) AS ipages,
    COALESCE(CEIL((c2.reltuples*(datahdr-12))/(bs-20::float)),0) AS iotta -- very rough approximation, assumes all cols
  FROM
     pg_class cc
  JOIN pg_namespace nn ON cc.relnamespace = nn.oid AND nn.nspname <> $$information_schema$$
  LEFT JOIN
  (
    SELECT
      ma,bs,foo.nspname,foo.relname,
      (datawidth+(hdr+ma-(case when hdr%ma=0 THEN ma ELSE hdr%ma END)))::numeric AS datahdr,
      (maxfracsum*(nullhdr+ma-(case when nullhdr%ma=0 THEN ma ELSE nullhdr%ma END))) AS nullhdr2
    FROM (
      SELECT
        ns.nspname, tbl.relname, hdr, ma, bs,
        SUM((1-coalesce(null_frac,0))*coalesce(avg_width, 2048)) AS datawidth,
        MAX(coalesce(null_frac,0)) AS maxfracsum,
        hdr+(
          SELECT 1+count(*)/8
          FROM pg_stats s2
          WHERE null_frac<>0 AND s2.schemaname = ns.nspname AND s2.tablename = tbl.relname
        )::numeric AS nullhdr
      FROM pg_attribute att 
      JOIN pg_class tbl ON att.attrelid = tbl.oid
      JOIN pg_namespace ns ON ns.oid = tbl.relnamespace 
      LEFT JOIN pg_stats s ON s.schemaname=ns.nspname
      AND s.tablename = tbl.relname
      AND s.inherited=false
      AND s.attname=att.attname,
      (
        SELECT
          (SELECT current_setting($$block_size$$)::numeric) AS bs,
            CASE WHEN SUBSTRING(SPLIT_PART(v, $$ $$, 2) FROM $$#"[0-9]+.[0-9]+#"%$$ for $$#$$)
              IN ($$8.0$$,$$8.1$$,$$8.2$$) THEN 27 ELSE 23 END AS hdr,
          CASE WHEN v ~ $$mingw32$$ OR v ~ $$64-bit$$ THEN 8 ELSE 4 END AS ma
        FROM (SELECT version() AS v) AS foo
      ) AS constants
      WHERE att.attnum > 0 AND tbl.relkind=$$r$$
      GROUP BY 1,2,3,4,5
    ) AS foo
  ) AS rs
  ON cc.relname = rs.relname AND nn.nspname = rs.nspname
  LEFT JOIN pg_index i ON indrelid = cc.oid
  LEFT JOIN pg_class c2 ON c2.oid = i.indexrelid
) AS sml order by wastedibytes desc limit 10;

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#VI">Back to Vacuum Information</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                 Tables age
-- -------------------------------------------------------------------------
\qecho <h3 id="12TA"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Tables age</b></font></h3>
\echo 'Query Tables age...'
\qecho <div style="overflow-x: auto; overflow-y: auto; min-height: 50px; max-height: 500px; width:%100px;">
select current_database(),rolname,nspname,relkind,relname,age(relfrozenxid),2^31-age(relfrozenxid) age_remain from pg_authid t1 join pg_class t2 on t1.oid=t2.relowner join pg_namespace t3 on t2.relnamespace=t3.oid where t2.relkind in ($$t$$,$$r$$) order by age(relfrozenxid) desc ;

\qecho </div>
\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#VI">Back to Vacuum Information</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                Vaccum settings of tables
-- -------------------------------------------------------------------------
\qecho <h3 id="12VS"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>vaccum settings of tables</b></font></h3>
\echo 'Query vaccum settings of tables ...'
\qecho <div style="overflow-x: auto; overflow-y: auto; min-height: 50px; max-height: 500px; width:%100px;">

SELECT n.nspname, c.relname,
pg_catalog.array_to_string(c.reloptions || array(
select 'toast.' ||
x from pg_catalog.unnest(tc.reloptions) x),', ')
as relopts
FROM pg_catalog.pg_class c
LEFT JOIN
pg_catalog.pg_class tc ON (c.reltoastrelid = tc.oid)
JOIN
pg_namespace n ON c.relnamespace = n.oid
WHERE c.relkind = 'r'
AND nspname NOT IN ('pg_catalog', 'information_schema');

\qecho </div>
\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#VI">Back to Vacuum Information</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                 Vacuum operation
-- -------------------------------------------------------------------------
\qecho <h3 id="12VO"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Vacuum Operation</b></font></h3>
\echo 'Query vacuum operation ...'
select * from pg_stat_progress_vacuum;

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#VI">Back to Vacuum Information</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                 Long transaction or 2pc
-- -------------------------------------------------------------------------
\qecho <h3 id="12LT"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Long transaction or 2pc</b></font></h3>
\echo 'Query Long transaction or 2pc ...'
select datname,usename,query,xact_start,now()-xact_start xact_duration,query_start,now()-query_start query_duration,state from sys_stat_activity where state<>$$idle$$ and (backend_xid is not null or backend_xmin is not null) and now()-xact_start > interval $$30 min$$ order by xact_start;
\qecho <hr align="left" size="1" color="Gray" width="20%" />
select name,statement,prepare_time,now()-prepare_time as prepare_wait_time,parameter_types,from_sql from pg_prepared_statements where now()-prepare_time > interval $$30 min$$ order by prepare_time;

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#VI">Back to Vacuum Information</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- ==============================================================================
--                               13. Backup Details
-- ==============================================================================


-- ==============================================================================
--                               14. Job / Schedules
-- ==============================================================================

-- ==============================================================================
--                               15. Parameters / Settings Details
-- ==============================================================================
\qecho <h3 id="PSD"><font size="+2" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Parameters / Settings Details</b></font></h3>
\qecho <ul>
\qecho <li><a href="#15CP">Customization Parameters</a></li>
\qecho <li><a href="#15PFS">Parameters File Settings</a></li>
\qecho <li><a href="#15DPS">Default Parameters Setting</a></li>
\qecho </ul>
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                         User or database level customization parameters       
-- -------------------------------------------------------------------------
\qecho <h3 id="15CP"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Customization parameters</b></font></h3>
\echo 'Query Customization parameters ...'
select * from sys_db_role_setting;

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#PSD">Back to Parameters / Settings Details</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                Parameters file Settings
-- -------------------------------------------------------------------------
\qecho <h3 id="15PFS"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Parameters file Settings</b></font></h3>
\echo 'Query parameter file settings ...'
\qecho <div style="overflow-x: auto; overflow-y: auto; min-height: 50px; max-height: 500px; width:%100px;">
SELECT sourcefile,name,setting,applied,error FROM pg_file_settings;
\qecho </div>

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#PSD">Back to Parameters / Settings Details</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- -------------------------------------------------------------------------
--                                Default Parameters Settings
-- -------------------------------------------------------------------------
\qecho <h3 id="15DPS"><font size="+1" face="Arial,Helvetica,Geneva,sans-serif" color="#336699"><b>Default Parameters Settings</b></font></h3>
\echo 'Query default parameter settings ...'
\qecho <div style="overflow-x: auto; overflow-y: auto; min-height: 50px; max-height: 500px; width:%100px;">
SELECT name,setting,unit,sourcefile FROM pg_settings;
\qecho </div>

\qecho <hr align="left" size="1" color="Gray" width="20%" />
\qecho <a href="#PSD">Back to Parameters / Settings Details</a>
\qecho <br />
\qecho <a href="#topics">Back to Top</a>

-- ==============================================================================
--                               16. Findings
-- ==============================================================================



-- ==============================================================================
--                          Report Ending Information
-- ==============================================================================
\qecho <div align="right"><font size="-1" face="Arial,Helvetica,Geneva,sans-serif" color="gray"><hr size="2" color="Gray" align="right" noshade/><b>Kingbase Database Health Check Snapshot</b>
\qecho <br />
\qecho <b>Copyright <sup>&reg;</sup> Kevin Ge, Kingbase Industrial Technical Service, All Rights Reserved</b>
\qecho <br />
\qecho <b>E-mail: gewenyu@kingbase.com.cn</b>
\qecho <br />
\qecho <b>Internal Version: :internalVersion</b>
\qecho <br />
</font>-
</div>

\echo 'End of health check report ...'
\echo 'Healthcheck_':datname'_':spooltime'.html'


\r
\q