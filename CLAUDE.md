# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`pg` is a comprehensive PostgreSQL database diagnostic command-line tool written in Bash. It provides monitoring, diagnostics, and performance analysis for PostgreSQL 9.6-18.

## Development Commands

```bash
# Run the tool
./pg --help
./pg ps                           # Process list
./pg diagnose health              # Health check

# Debug queries (shows SQL and timing)
DEBUG_QUERIES=1 ./pg ps

# Connect with specific parameters
./pg -h localhost -p 5432 -u postgres -d mydb ps
```

## Architecture

Single-file Bash application (`pg`) with command dispatch pattern:

- **Entry point**: Command-line args parsed, then `dispatch_command()` routes to `cmd_<name>()` functions
- **Query helpers**:
  - `q()` - Execute SQL query via psql, returns formatted output
  - `q_scalar()` - Returns single value (no headers), for arithmetic use
  - `q_sanitize()` - Input sanitization to prevent SQL injection
- **Version compatibility**: `init_version_features()` detects PG version and sets feature flags (e.g., `HAS_PG_WAIT_EVENTS`, `HAS_REPLICATION_SLOTS`)
- **Error handling**: `safe_execute()`, `require_extension()`, `require_privilege()`, `require_superuser()`

## Command Categories

Organized in `dispatch_command()` case statement:
- Quick diagnostics: `ps`, `running`, `blocking`, `locks`, `kill`, `cancel`
- Slow query: `slow`, `top_time`, `top_calls`, `top_io`
- Table/Index: `table_size`, `bloat`, `unused_indexes`, `missing_indexes`
- Performance: `cache_hit`, `io_stats`, `wait_events`
- Diagnose scenarios: `diagnose health|performance|connection|blocking|replication|security|storage`

## Adding New Commands

1. Add `cmd_<name>()` function implementing the command
2. Add case entry in `dispatch_command()` to route to the function
3. Add usage text in `usage()` function
4. Update README.md command tables if significant

## Version Compatibility

When writing SQL queries, check PG version for feature availability:
```bash
if [ "$PG_MAJOR_VERSION" -ge 17 ]; then
  # Use PG 17+ specific columns
fi
```

Key version differences handled:
- PG 13+: `pg_stat_statements` uses `total_exec_time` vs `total_time`
- PG 17+: `pg_stat_checkpointer` replaces `pg_stat_bgwriter` checkpoint columns
- PG 17+: `pg_wait_events` system view available

## Required Extensions

Some commands require `pg_stat_statements`. Check with `require_extension pg_stat_statements` before using.