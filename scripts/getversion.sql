select 'db version' ,version 
union all 
select 'build version' ,build_version 
union all 
select 'pg version',setting from pg_settings where name='server_version' 
union all 
select 'license valid days',to_char(get_license_validdays());
