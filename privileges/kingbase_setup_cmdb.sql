-- ============================================
-- Kingbase CMDB 采集用户权限配置 - 一键脚本
-- 执行用户：system（超级用户）
-- 数据库：test

-- 说明：
-- cmdb_monitor: 角色名称，用于统一管理权限
-- NOLOGIN: 角色不能直接登录，只能通过继承被使用
-- cmdb_collector: 采集用户名称，需要修改密码为强密码
-- PASSWORD: 设置采集用户密码，建议使用复杂密码
-- CONNECT ON DATABASE: 允许连接指定数据库
-- SELECT ON TABLE: 允许查询指定表
-- USAGE ON SCHEMA: 允许访问指定 schema
-- SELECT ON ALL TABLES: 允许查询 schema 中的所有表
-- ============================================

-- 创建角色和用户
CREATE ROLE cmdb_monitor NOLOGIN;
CREATE USER cmdb_collector WITH PASSWORD 'your_strong_password_here';
GRANT cmdb_monitor TO cmdb_collector;

-- 授予基础权限
GRANT CONNECT ON DATABASE test TO cmdb_monitor;
GRANT SELECT ON TABLE sys_database TO cmdb_monitor;
GRANT SELECT ON TABLE sys_user TO cmdb_monitor;

-- 授予 schema 权限
GRANT USAGE ON SCHEMA information_schema TO cmdb_monitor;
GRANT SELECT ON ALL TABLES IN SCHEMA information_schema TO cmdb_monitor;
GRANT USAGE ON SCHEMA pg_catalog TO cmdb_monitor;
GRANT SELECT ON TABLE pg_catalog.pg_database TO cmdb_monitor;
GRANT SELECT ON TABLE pg_catalog.pg_user TO cmdb_monitor;

-- 授予敏感参数权限
GRANT sys_read_all_settings TO cmdb_monitor;

-- 授予函数权限
GRANT EXECUTE ON FUNCTION GET_LICENSE_VALIDDAYS() TO cmdb_monitor;

-- 创建参数视图(可选)
CREATE SCHEMA IF NOT EXISTS cmdb_schema;
CREATE OR REPLACE VIEW cmdb_schema.system_config AS
  SELECT 
    current_setting('max_connections')::TEXT as max_connections,
    current_setting('server_encoding')::TEXT as server_encoding,
    current_setting('enable_ci')::TEXT as case_sensitive,
    current_setting('shared_buffers')::TEXT as shared_buffers,
    current_setting('database_mode')::TEXT as database_mode,
    current_setting('config_file')::TEXT as config_file,
    current_setting('hba_file')::TEXT as hba_file,
    current_setting('ident_file')::TEXT as ident_file;

GRANT USAGE ON SCHEMA cmdb_schema TO cmdb_monitor;
GRANT SELECT ON cmdb_schema.system_config TO cmdb_monitor;

-- 设置安全参数
ALTER ROLE cmdb_monitor NOSUPERUSER;
ALTER ROLE cmdb_monitor NOCREATEDB;
ALTER ROLE cmdb_monitor NOCREATEROLE;
ALTER ROLE cmdb_monitor CONNECTION LIMIT 5;


-- 方式1：使用 REVOKE 语句
REVOKE ALL ON SCHEMA public FROM cmdb_collector CASCADE;
REVOKE ALL ON SCHEMA public FROM cmdb_monitor CASCADE;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM cmdb_collector CASCADE;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM cmdb_monitor CASCADE;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM cmdb_collector CASCADE;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM cmdb_monitor CASCADE;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM cmdb_collector CASCADE;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM cmdb_monitor CASCADE; 


-- 撤销 public 角色对 public schema 的默认权限
REVOKE ALL ON SCHEMA public FROM public;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM public;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM public;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM public;


-- 权限检查脚本
-- 以 system 用户执行以下脚本进行完整的权限检查：
-- 验证
SELECT '========== 配置完成，权限验证 ==========' as status;
-- ========== 权限检查脚本 ==========

-- 1. 检查用户和角色关系
SELECT '1. 用户和角色关系' as check_item;
SELECT 
  u.usename as user_name,
  r.rolname as role_name,
  CASE 
    WHEN r.rolname = 'sys_read_all_settings' THEN '敏感参数权限'
    ELSE '基础角色'
  END as permission_type
FROM sys_user u
LEFT JOIN sys_auth_members m ON u.usesysid = m.member
LEFT JOIN sys_roles r ON m.roleid = r.oid
WHERE u.usename = 'cmdb_collector'
ORDER BY r. rolname;

-- 2. 检查数据库连接权限
SELECT '2. 数据库连接权限' as check_item;
SELECT 
  grantee,
  table_catalog as database_name,
  privilege_type
FROM information_schema.role_table_grants
WHERE grantee = 'cmdb_monitor' 
  AND table_schema = 'information_schema'
LIMIT 5;

-- 3. 检查对象权限
SELECT '3. 系统表权限' as check_item;
SELECT 
  grantee,
  table_schema,
  table_name,
  privilege_type
FROM information_schema.table_privileges
WHERE grantee = 'cmdb_monitor'
  AND table_schema IN ('public', 'sys')
ORDER BY table_name;

-- 4. 检查函数权限
SELECT '4. 函数执行权限' as check_item;
SELECT 
  grantee,
  routine_schema,
  routine_name,
  privilege_type
FROM information_schema.routine_privileges
WHERE grantee = 'cmdb_monitor';

-- 5. 特别检查 sys_read_all_settings
SELECT '5. 敏感参数权限特别检查' as check_item;
SELECT 
  r1.rolname as role_name,
  r2.rolname as granted_role,
  '已授予' as status
FROM sys_roles r1
JOIN sys_auth_members m ON r1.oid = m. member
JOIN sys_roles r2 ON m.roleid = r2.oid
WHERE r1.rolname = 'cmdb_monitor' 
  AND r2.rolname = 'sys_read_all_settings';


