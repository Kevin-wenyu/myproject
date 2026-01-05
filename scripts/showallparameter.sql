--show all;
select name,context,substr(setting,1,38) as setting,unit,short_desc from pg_settings 
where name not in('shared_preload_libraries','log_line_prefix','ssl_passphrase_command_supports_reload');
